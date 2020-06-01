// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'package:args/args.dart';

import '../android/android.dart' as android;
import '../android/android_sdk.dart' as android_sdk;
import '../android/gradle_utils.dart' as gradle;
import '../base/common.dart';
import '../base/context.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/net.dart';
import '../base/utils.dart';
import '../cache.dart';
import '../convert.dart';
import '../dart/pub.dart';
import '../features.dart';
import '../flutter_project_metadata.dart';
import '../globals.dart' as globals;
import '../project.dart';
import '../reporting/reporting.dart';
import '../runner/flutter_command.dart';
import '../template.dart';

class PluginAddPlatformsCommand extends FlutterCommand {
  PluginAddPlatformsCommand({ bool verboseHelp = false }) {
    argParser.addFlag('pub',
      defaultsTo: true,
      help: 'Whether to run "flutter pub get" after the plugin has been created.',
    );
    argParser.addOption(
      'ios-language',
      abbr: 'i',
      defaultsTo: 'swift',
      allowed: <String>['objc', 'swift'],
    );
    argParser.addOption(
      'android-language',
      abbr: 'a',
      defaultsTo: 'kotlin',
      allowed: <String>['java', 'kotlin'],
    );
    usesTrackWidgetCreation(verboseHelp: verboseHelp);
  }

  @override
  final String name = 'add-platforms';

  @override
  final String description = 'Commands to create a Flutter plugins';

  @override
  String get invocation => '${runner.executableName} $name <output directory>';

  @override
  Future<Map<CustomDimensions, String>> get usageValues async {
    return <CustomDimensions, String>{
      CustomDimensions.commandCreateAndroidLanguage: stringArg('android-language'),
      CustomDimensions.commandCreateIosLanguage: stringArg('ios-language'),
    };
  }

  // Lazy-initialize the net utilities with values from the context.
  Net _cachedNet;
  Net get _net => _cachedNet ??= Net(
    httpClientFactory: context.get<HttpClientFactory>() ?? () => HttpClient(),
    logger: globals.logger,
    platform: globals.platform,
  );

  bool _isPluginProject(Directory projectDir) {
    final File metadataFile = globals.fs.file(globals.fs.path.join(projectDir.absolute.path, '.metadata'));
    final FlutterProjectMetadata projectMetadata = FlutterProjectMetadata(metadataFile, globals.logger);
    return projectMetadata.projectType == FlutterProjectType.plugin;
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    if (argResults.rest.isEmpty) {
      throwToolExit('No option specified for the output directory.\n$usage', exitCode: 2);
    }

    if (argResults.rest.length > 1) {
      String message = 'Multiple output directories specified.';
      for (final String arg in argResults.rest) {
        if (arg.startsWith('-')) {
          message += '\nTry moving $arg to be immediately following $name';
          break;
        }
      }
      throwToolExit(message, exitCode: 2);
    }

    if (Cache.flutterRoot == null) {
      throwToolExit('Neither the --flutter-root command line flag nor the FLUTTER_ROOT environment '
        'variable was specified. Unable to find package:flutter.', exitCode: 2);
    }

    final String flutterRoot = globals.fs.path.absolute(Cache.flutterRoot);

    final String flutterPackagesDirectory = globals.fs.path.join(flutterRoot, 'packages');
    final String flutterPackagePath = globals.fs.path.join(flutterPackagesDirectory, 'flutter');
    if (!globals.fs.isFileSync(globals.fs.path.join(flutterPackagePath, 'pubspec.yaml'))) {
      throwToolExit('Unable to find package:flutter in $flutterPackagePath', exitCode: 2);
    }

    final String flutterDriverPackagePath = globals.fs.path.join(flutterRoot, 'packages', 'flutter_driver');
    if (!globals.fs.isFileSync(globals.fs.path.join(flutterDriverPackagePath, 'pubspec.yaml'))) {
      throwToolExit('Unable to find package:flutter_driver in $flutterDriverPackagePath', exitCode: 2);
    }

    final Directory projectDir = globals.fs.directory(argResults.rest.first);
    final String projectDirPath = globals.fs.path.normalize(projectDir.absolute.path);

    String organization = stringArg('org');
    if (!argResults.wasParsed('org')) {
      final FlutterProject project = FlutterProject.fromDirectory(projectDir);
      final Set<String> existingOrganizations = await project.organizationNames;
      if (existingOrganizations.length == 1) {
        organization = existingOrganizations.first;
      } else if (existingOrganizations.length > 1) {
        throwToolExit(
          'Ambiguous organization in existing files: $existingOrganizations. '
          'The --org command line argument must be specified to recreate project.'
        );
      }
    }

    final bool overwrite = boolArg('overwrite');
    String error = _validateProjectDir(projectDirPath, flutterRoot: flutterRoot, overwrite: overwrite);
    if (error != null) {
      throwToolExit(error);
    }

    final String projectName = stringArg('project-name') ?? globals.fs.path.basename(projectDirPath);
    error = _validateProjectName(projectName);
    if (error != null) {
      throwToolExit(error);
    }

    final Map<String, dynamic> templateContext = _templateContext(
      organization: organization,
      projectName: projectName,
      projectDescription: stringArg('description'),
      flutterRoot: flutterRoot,
      renderDriverTest: boolArg('with-driver-test'),
      androidLanguage: stringArg('android-language'),
      iosLanguage: stringArg('ios-language'),
      web: featureFlags.isWebEnabled,
      linux: featureFlags.isLinuxEnabled,
      macos: featureFlags.isMacOSEnabled,
      windows: featureFlags.isWindowsEnabled,
    );

    final String relativeDirPath = globals.fs.path.relative(projectDirPath);
    if (!projectDir.existsSync() || projectDir.listSync().isEmpty) {
      globals.printStatus('Creating project $relativeDirPath...');
    } else {
      if (!overwrite) {
        throwToolExit('Will not overwrite existing project in $relativeDirPath: '
          'must specify --overwrite for samples to overwrite.');
      }
      globals.printStatus('Recreating project $relativeDirPath...');
    }

    final Directory relativeDir = globals.fs.directory(projectDirPath);
    int generatedFileCount = 0;

    generatedFileCount += await _generatePlugin(relativeDir, templateContext, overwrite: overwrite);

    globals.printStatus('Wrote $generatedFileCount files.');
    globals.printStatus('\nAll done!');
    const String application = 'application';

    // Run doctor; tell the user the next steps.
    final FlutterProject project = FlutterProject.fromPath(projectDirPath);
    final FlutterProject app = project.hasExampleApp ? project.example : project;
    final String relativeAppPath = globals.fs.path.normalize(globals.fs.path.relative(app.directory.path));
    final String relativeAppMain = globals.fs.path.join(relativeAppPath, 'lib', 'main.dart');
    final String relativePluginPath = globals.fs.path.normalize(globals.fs.path.relative(projectDirPath));
    final String relativePluginMain = globals.fs.path.join(relativePluginPath, 'lib', '$projectName.dart');
    if (globals.doctor.canLaunchAnything) {
      // Let them know a summary of the state of their tooling.
      await globals.doctor.summary();

      globals.printStatus('''
In order to run your $application, type:

\$ cd $relativeAppPath
\$ flutter run

Your $application code is in $relativeAppMain.
''');
      globals.printStatus('''
Your plugin code is in $relativePluginMain.

Host platform code is in the "android" and "ios" directories under $relativePluginPath.
To edit platform code in an IDE see https://flutter.dev/developing-packages/#edit-plugin-package.
''');
      // Warn about unstable templates. This shuold be last so that it's not
      // lost among the other output.
      if (featureFlags.isLinuxEnabled) {
        globals.printStatus('');
        globals.printStatus('WARNING: The Linux tooling and APIs are not yet stable. '
            'You will likely need to re-create the "linux" directory after future '
            'Flutter updates.');
      }
      if (featureFlags.isWindowsEnabled) {
        globals.printStatus('');
        globals.printStatus('WARNING: The Windows tooling and APIs are not yet stable. '
            'You will likely need to re-create the "windows" directory after future '
            'Flutter updates.');
      }
    }
    return FlutterCommandResult.success();
  }

  Future<int> _generatePlugin(Directory directory, Map<String, dynamic> templateContext, { bool overwrite = false }) async {
    int generatedCount = 0;
    final String description = argResults.wasParsed('description')
        ? stringArg('description')
        : 'A new flutter plugin project.';
    templateContext['description'] = description;
    generatedCount += await _renderTemplate('plugin', directory, templateContext, overwrite: overwrite);
    if (boolArg('pub')) {
      await pub.get(
        context: PubContext.createPlugin,
        directory: directory.path,
        offline: boolArg('offline'),
      );
    }
    final FlutterProject project = FlutterProject.fromDirectory(directory);
    gradle.updateLocalProperties(project: project, requireAndroidSdk: false);

    final String projectName = templateContext['projectName'] as String;
    final String organization = templateContext['organization'] as String;
    final String androidPluginIdentifier = templateContext['androidIdentifier'] as String;
    final String exampleProjectName = projectName + '_example';
    templateContext['projectName'] = exampleProjectName;
    templateContext['androidIdentifier'] = _createAndroidIdentifier(organization, exampleProjectName);
    templateContext['iosIdentifier'] = _createUTIIdentifier(organization, exampleProjectName);
    templateContext['description'] = 'Demonstrates how to use the $projectName plugin.';
    templateContext['pluginProjectName'] = projectName;
    templateContext['androidPluginIdentifier'] = androidPluginIdentifier;

    generatedCount += await _generateApp(project.example.directory, templateContext, overwrite: overwrite);
    return generatedCount;
  }

  Future<int> _generateApp(Directory directory, Map<String, dynamic> templateContext, { bool overwrite = false }) async {
    int generatedCount = 0;
    generatedCount += await _renderTemplate('app', directory, templateContext, overwrite: overwrite);
    final FlutterProject project = FlutterProject.fromDirectory(directory);
    generatedCount += _injectGradleWrapper(project);

    if (boolArg('with-driver-test')) {
      final Directory testDirectory = directory.childDirectory('test_driver');
      generatedCount += await _renderTemplate('driver', testDirectory, templateContext, overwrite: overwrite);
    }

    if (boolArg('pub')) {
      await pub.get(context: PubContext.create, directory: directory.path, offline: boolArg('offline'));
      await project.ensureReadyForPlatformSpecificTooling(checkProjects: false);
    }

    gradle.updateLocalProperties(project: project, requireAndroidSdk: false);

    return generatedCount;
  }

  Map<String, dynamic> _templateContext({
    String organization,
    String projectName,
    String projectDescription,
    String androidLanguage,
    String iosLanguage,
    String flutterRoot,
    bool renderDriverTest = false,
    bool web = false,
    bool linux = false,
    bool macos = false,
    bool windows = false,
  }) {
    flutterRoot = globals.fs.path.normalize(flutterRoot);

    final String pluginDartClass = _createPluginClassName(projectName);
    final String pluginClass = pluginDartClass.endsWith('Plugin')
        ? pluginDartClass
        : pluginDartClass + 'Plugin';
    final String appleIdentifier = _createUTIIdentifier(organization, projectName);

    return <String, dynamic>{
      'organization': organization,
      'projectName': projectName,
      'androidIdentifier': _createAndroidIdentifier(organization, projectName),
      'iosIdentifier': appleIdentifier,
      'macosIdentifier': appleIdentifier,
      'description': projectDescription,
      'dartSdk': '$flutterRoot/bin/cache/dart-sdk',
      'useAndroidEmbeddingV2': featureFlags.isAndroidEmbeddingV2Enabled,
      'androidMinApiLevel': android.minApiLevel,
      'androidSdkVersion': android_sdk.minimumAndroidSdkVersion,
      'withDriverTest': renderDriverTest,
      'pluginClass': pluginClass,
      'pluginDartClass': pluginDartClass,
      'pluginCppHeaderGuard': projectName.toUpperCase(),
      'pluginProjectUUID': Uuid().v4().toUpperCase(),
      'androidLanguage': androidLanguage,
      'iosLanguage': iosLanguage,
      'flutterRevision': globals.flutterVersion.frameworkRevision,
      'flutterChannel': globals.flutterVersion.channel,
      'web': web,
      'linux': linux,
      'macos': macos,
      'windows': windows,
      'year': DateTime.now().year,
    };
  }

  Future<int> _renderTemplate(String templateName, Directory directory, Map<String, dynamic> context, { bool overwrite = false }) async {
    final Template template = await Template.fromName(templateName, fileSystem: globals.fs);
    return template.render(directory, context, overwriteExisting: overwrite);
  }

  int _injectGradleWrapper(FlutterProject project) {
    int filesCreated = 0;
    globals.fsUtils.copyDirectorySync(
      globals.cache.getArtifactDirectory('gradle_wrapper'),
      project.android.hostAppGradleRoot,
      onFileCopied: (File sourceFile, File destinationFile) {
        filesCreated++;
        final String modes = sourceFile.statSync().modeString();
        if (modes != null && modes.contains('x')) {
          globals.os.makeExecutable(destinationFile);
        }
      },
    );
    return filesCreated;
  }
}

String _createAndroidIdentifier(String organization, String name) {
  // Android application ID is specified in: https://developer.android.com/studio/build/application-id
  // All characters must be alphanumeric or an underscore [a-zA-Z0-9_].
  String tmpIdentifier = '$organization.$name';
  final RegExp disallowed = RegExp(r'[^\w\.]');
  tmpIdentifier = tmpIdentifier.replaceAll(disallowed, '');

  // It must have at least two segments (one or more dots).
  final List<String> segments = tmpIdentifier
      .split('.')
      .where((String segment) => segment.isNotEmpty)
      .toList();
  while (segments.length < 2) {
    segments.add('untitled');
  }

  // Each segment must start with a letter.
  final RegExp segmentPatternRegex = RegExp(r'^[a-zA-Z][\w]*$');
  final List<String> prefixedSegments = segments
      .map((String segment) {
        if (!segmentPatternRegex.hasMatch(segment)) {
          return 'u'+segment;
        }
        return segment;
      })
      .toList();
  return prefixedSegments.join('.');
}

String _createPluginClassName(String name) {
  final String camelizedName = camelCase(name);
  return camelizedName[0].toUpperCase() + camelizedName.substring(1);
}

String _createUTIIdentifier(String organization, String name) {
  // Create a UTI (https://en.wikipedia.org/wiki/Uniform_Type_Identifier) from a base name
  name = camelCase(name);
  String tmpIdentifier = '$organization.$name';
  final RegExp disallowed = RegExp(r'[^a-zA-Z0-9\-\.\u0080-\uffff]+');
  tmpIdentifier = tmpIdentifier.replaceAll(disallowed, '');

  // It must have at least two segments (one or more dots).
  final List<String> segments = tmpIdentifier
      .split('.')
      .where((String segment) => segment.isNotEmpty)
      .toList();
  while (segments.length < 2) {
    segments.add('untitled');
  }

  return segments.join('.');
}

const Set<String> _packageDependencies = <String>{
  'analyzer',
  'args',
  'async',
  'collection',
  'convert',
  'crypto',
  'flutter',
  'flutter_test',
  'front_end',
  'html',
  'http',
  'intl',
  'io',
  'isolate',
  'kernel',
  'logging',
  'matcher',
  'meta',
  'mime',
  'path',
  'plugin',
  'pool',
  'test',
  'utf',
  'watcher',
  'yaml',
};

// A valid Dart identifier.
// https://dart.dev/guides/language/language-tour#important-concepts
final RegExp _identifierRegExp = RegExp('[a-zA-Z_][a-zA-Z0-9_]*');

// non-contextual dart keywords.
//' https://dart.dev/guides/language/language-tour#keywords
const Set<String> _keywords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'inout',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'native',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'out',
  'part',
  'patch',
  'required',
  'rethrow',
  'return',
  'set',
  'show',
  'source',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

/// Whether [name] is a valid Pub package.
@visibleForTesting
bool isValidPackageName(String name) {
  final Match match = _identifierRegExp.matchAsPrefix(name);
  return match != null && match.end == name.length && !_keywords.contains(name);
}

/// Return null if the project name is legal. Return a validation message if
/// we should disallow the project name.
String _validateProjectName(String projectName) {
  if (!isValidPackageName(projectName)) {
    return '"$projectName" is not a valid Dart package name.\n\n'
      'See https://dart.dev/tools/pub/pubspec#name for more information.';
  }
  if (_packageDependencies.contains(projectName)) {
    return "Invalid project name: '$projectName' - this will conflict with Flutter "
      'package dependencies.';
  }
  return null;
}

/// Return null if the project directory is legal. Return a validation message
/// if we should disallow the directory name.
String _validateProjectDir(String dirPath, { String flutterRoot, bool overwrite = false }) {
  if (globals.fs.path.isWithin(flutterRoot, dirPath)) {
    return 'Cannot create a project within the Flutter SDK. '
      "Target directory '$dirPath' is within the Flutter SDK at '$flutterRoot'.";
  }

  // If the destination directory is actually a file, then we refuse to
  // overwrite, on the theory that the user probably didn't expect it to exist.
  if (globals.fs.isFileSync(dirPath)) {
    final String message = "Invalid project name: '$dirPath' - refers to an existing file.";
    return overwrite
      ? '$message Refusing to overwrite a file with a directory.'
      : message;
  }

  if (overwrite) {
    return null;
  }

  final FileSystemEntityType type = globals.fs.typeSync(dirPath);

  if (type != FileSystemEntityType.notFound) {
    switch (type) {
      case FileSystemEntityType.file:
        // Do not overwrite files.
        return "Invalid project name: '$dirPath' - file exists.";
      case FileSystemEntityType.link:
        // Do not overwrite links.
        return "Invalid project name: '$dirPath' - refers to a link.";
    }
  }

  return null;
}
