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
import 'plugin_create.dart';
import 'plugin_add_platforms.dart';

class PluginCommand extends FlutterCommand {
  PluginCommand({bool verboseHelp = false}) {
    addSubcommand(PluginCreateCommand());
    addSubcommand(PluginAddPlatformsCommand());
  }

  @override
  final String name = 'plugin';

  @override
  final String description = 'Commands related to Flutter plugins';

  @override
  Future<FlutterCommandResult> runCommand() async => null;
}

mixin PluginCommandMixin on FlutterCommand {
  void addPlatformsOptions() {
    argParser.addMultiOption('platforms',
        help: 'the platforms supported by this plugin.',
        allowed: <String>[
          'ios',
          'android',
          'windows',
          'linux',
          'macos',
          'web'
        ]);
  }

  void addPubFlag() {
    argParser.addFlag(
      'pub',
      defaultsTo: false,
      help:
          'Whether to run "flutter pub get" after the project has been updated.',
    );
  }

  void addOfflineFlag() {
    argParser.addFlag(
      'offline',
      defaultsTo: false,
      help:
          'When "flutter pub get" is run by the plugin command, this indicates '
          'whether to run it in offline mode or not. In offline mode, it will need to '
          'have all dependencies already available in the pub cache to succeed.',
    );
  }

  void addOverwriteFlag() {
    argParser.addFlag(
      'overwrite',
      negatable: true,
      defaultsTo: false,
      help: 'When performing operations, overwrite existing files.',
    );
  }

  void addIOSLanguageFlag() {
    argParser.addOption(
      'ios-language',
      abbr: 'i',
      defaultsTo: 'swift',
      allowed: <String>['objc', 'swift'],
    );
  }

  void addAndroidLanguageFlag() {
    argParser.addOption(
      'android-language',
      abbr: 'a',
      defaultsTo: 'kotlin',
      allowed: <String>['java', 'kotlin'],
    );
  }

  void addOrgFlag() {
    argParser.addOption(
      'org',
      defaultsTo: 'com.example',
      help:
          'The organization responsible for your new Flutter plugin project, in reverse domain name notation. '
          'This string is used in Java package names and as prefix in the iOS bundle identifier.',
    );
  }

  Future<Map<String, dynamic>> validateArgsAndCreateTemplate(
      final ArgParser argParser) async {

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

    final String flutterPackagesDirectory =
        globals.fs.path.join(flutterRoot, 'packages');
    final String flutterPackagePath =
        globals.fs.path.join(flutterPackagesDirectory, 'flutter');
    if (!globals.fs
        .isFileSync(globals.fs.path.join(flutterPackagePath, 'pubspec.yaml'))) {
      throwToolExit('Unable to find package:flutter in $flutterPackagePath',
          exitCode: 2);
    }

    final String flutterDriverPackagePath =
        globals.fs.path.join(flutterRoot, 'packages', 'flutter_driver');
    if (!globals.fs.isFileSync(
        globals.fs.path.join(flutterDriverPackagePath, 'pubspec.yaml'))) {
      throwToolExit(
          'Unable to find package:flutter_driver in $flutterDriverPackagePath',
          exitCode: 2);
    }

    final Directory projectDir = globals.fs.directory(argResults.rest.first);
    final String projectDirPath =
        globals.fs.path.normalize(projectDir.absolute.path);
    final FlutterProject project = FlutterProject.fromDirectory(projectDir);

    String organization = stringArg('org');
    if (!argResults.wasParsed('org')) {
      final FlutterProject project = FlutterProject.fromDirectory(projectDir);
      final Set<String> existingOrganizations = await project.organizationNames;
      if (existingOrganizations.length == 1) {
        organization = existingOrganizations.first;
      } else if (existingOrganizations.length > 1) {
        throwToolExit(
            'Ambiguous organization in existing files: $existingOrganizations. '
            'The --org command line argument must be specified to recreate project.');
      }
    }

    final bool overwrite = boolArg('overwrite');
    String error = _validateProjectDir(projectDirPath,
        flutterRoot: flutterRoot, overwrite: overwrite);
    if (error != null) {
      throwToolExit(error);
    }

    final String projectName =
        argResults.arguments.contains('project-name') ? stringArg('project-name') : globals.fs.path.basename(projectDirPath);
    error = _validateProjectName(projectName);
    if (error != null) {
      throwToolExit(error);
    }
    final List<String> platforms = stringsArg('platforms');
    if (platforms == null || platforms.isEmpty) {
      throwToolExit(
          'Must specify ast least 1 platform using the --platforms flag');
    }
    final String description =
        argResults.arguments.contains('description') ? stringArg('description') : project.manifest.description;
    return _createTemplateContext(
      organization: organization,
      projectName: projectName,
      projectDescription: description,
      flutterRoot: flutterRoot,
      renderDriverTest: boolArg('with-driver-test'),
      androidLanguage: stringArg('android-language'),
      iosLanguage: stringArg('ios-language'),
      ios: platforms.contains('ios'),
      generateAndroid: platforms.contains('android'),
      web: platforms.contains('web'),
      linux: platforms.contains('linux'),
      macos: platforms.contains('macos'),
      windows: platforms.contains('windows'),
    );
  }

  Map<String, dynamic> _createTemplateContext({
    String organization,
    String projectName,
    String projectDescription,
    String androidLanguage,
    String iosLanguage,
    String flutterRoot,
    bool renderDriverTest = false,
    bool ios = false,
    bool generateAndroid = false,
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
    final String appleIdentifier =
        createUTIIdentifier(organization, projectName);

    return <String, dynamic>{
      'organization': organization,
      'projectName': projectName,
      'androidIdentifier': createAndroidIdentifier(organization, projectName),
      'iosIdentifier': appleIdentifier,
      'macosIdentifier': appleIdentifier,
      'description': projectDescription,
      'dartSdk': '$flutterRoot/bin/cache/dart-sdk',
      'useAndroidEmbeddingV2': featureFlags.isAndroidEmbeddingV2Enabled,
      'androidMinApiLevel': android.minApiLevel,
      'androidSdkVersion': android_sdk.minimumAndroidSdkVersion,
      'withDriverTest': renderDriverTest,
      'withPluginHook': true,
      'pluginClass': pluginClass,
      'pluginDartClass': pluginDartClass,
      'pluginCppHeaderGuard': projectName.toUpperCase(),
      'pluginProjectUUID': Uuid().v4().toUpperCase(),
      'androidLanguage': androidLanguage,
      'iosLanguage': iosLanguage,
      'flutterRevision': globals.flutterVersion.frameworkRevision,
      'flutterChannel': globals.flutterVersion.channel,
      'ios': ios,
      'android': generateAndroid,
      'web': web,
      'linux': linux,
      'macos': macos,
      'windows': windows,
      'year': DateTime.now().year,
    };
  }

  Future<int> renderTemplate(
      String templateName, Directory directory, Map<String, dynamic> context,
      {bool overwrite = false}) async {
    final Template template =
        await Template.fromName(templateName, fileSystem: globals.fs);
    return template.render(directory, context, overwriteExisting: overwrite);
  }

  String createAndroidIdentifier(String organization, String name) {
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
    final List<String> prefixedSegments = segments.map((String segment) {
      if (!segmentPatternRegex.hasMatch(segment)) {
        return 'u' + segment;
      }
      return segment;
    }).toList();
    return prefixedSegments.join('.');
  }

  String _createPluginClassName(String name) {
    final String camelizedName = camelCase(name);
    return camelizedName[0].toUpperCase() + camelizedName.substring(1);
  }

  String createUTIIdentifier(String organization, String name) {
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

  /// Whether [name] is a valid Pub package.
  @visibleForTesting
  bool isValidPackageName(String name) {
    final Match match = _identifierRegExp.matchAsPrefix(name);
    return match != null &&
        match.end == name.length &&
        !_keywords.contains(name);
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
  String _validateProjectDir(String dirPath,
      {String flutterRoot, bool overwrite = false}) {
    if (globals.fs.path.isWithin(flutterRoot, dirPath)) {
      return 'Cannot create a project within the Flutter SDK. '
          "Target directory '$dirPath' is within the Flutter SDK at '$flutterRoot'.";
    }

    // If the destination directory is actually a file, then we refuse to
    // overwrite, on the theory that the user probably didn't expect it to exist.
    if (globals.fs.isFileSync(dirPath)) {
      final String message =
          "Invalid project name: '$dirPath' - refers to an existing file.";
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

  final Set<String> _packageDependencies = <String>{
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
  final Set<String> _keywords = <String>{
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
}
