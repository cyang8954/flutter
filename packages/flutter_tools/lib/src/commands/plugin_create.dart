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
import 'plugin.dart';

class PluginCreateCommand extends FlutterCommand with PluginCommandMixin{
  PluginCreateCommand() {
    addPlatformsOptions();
    addPubFlag();
    addOfflineFlag();
    addOverwriteFlag();
    addIOSLanguageFlag();
    addAndroidLanguageFlag();
    addOrgFlag();
    argParser.addFlag(
      'with-driver-test',
      negatable: true,
      defaultsTo: false,
      help: "Also add a flutter_driver dependency and generate a sample 'flutter drive' test.",
    );

    argParser.addOption(
      'description',
      defaultsTo: 'A new Flutter plugin project.',
      help: 'The description to use for your new Flutter plugin project. This string ends up in the pubspec.yaml file.',
    );
    argParser.addOption(
      'project-name',
      defaultsTo: null,
      help: 'The project name for this new Flutter project. This must be a valid dart package name.',
    );
  }

  @override
  final String name = 'create';

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
    final Map<String, dynamic> templateContext = await validateArgsAndCreateTemplate(argParser);
    final bool overwrite = boolArg('overwrite');
    final Directory projectDir = globals.fs.directory(argResults.rest.first);
    final String projectDirPath =
        globals.fs.path.normalize(projectDir.absolute.path);

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
    final String relativePluginMain = globals.fs.path.join(relativePluginPath, 'lib', '${project.manifest.appName}.dart');
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
    generatedCount += await renderTemplate('plugin', directory, templateContext, overwrite: overwrite);
    if (boolArg('pub')) {
      await pub.get(
        context: PubContext.createPlugin,
        directory: directory.path,
        offline: boolArg('offline'),
      );
    }
    final FlutterProject project = FlutterProject.fromDirectory(directory);
    if (templateContext['android'] as bool) {
      gradle.updateLocalProperties(project: project, requireAndroidSdk: false);
    }

    final String projectName = templateContext['projectName'] as String;
    final String organization = templateContext['organization'] as String;
    final String androidPluginIdentifier = templateContext['androidIdentifier'] as String;
    final String exampleProjectName = projectName + '_example';
    templateContext['projectName'] = exampleProjectName;
    templateContext['androidIdentifier'] = createAndroidIdentifier(organization, exampleProjectName);
    templateContext['iosIdentifier'] = createUTIIdentifier(organization, exampleProjectName);
    templateContext['description'] = 'Demonstrates how to use the $projectName plugin.';
    templateContext['pluginProjectName'] = projectName;
    templateContext['androidPluginIdentifier'] = androidPluginIdentifier;

    generatedCount += await _generateApp(project.example.directory, templateContext, overwrite: overwrite);
    return generatedCount;
  }

  Future<int> _generateApp(Directory directory, Map<String, dynamic> templateContext, { bool overwrite = false }) async {
    int generatedCount = 0;
    generatedCount += await renderTemplate('app', directory, templateContext, overwrite: overwrite);
    final FlutterProject project = FlutterProject.fromDirectory(directory);
    if (templateContext['android'] as bool) {
      generatedCount += _injectGradleWrapper(project);
    }

    if (boolArg('with-driver-test')) {
      final Directory testDirectory = directory.childDirectory('test_driver');
      generatedCount += await renderTemplate('driver', testDirectory, templateContext, overwrite: overwrite);
    }

    if (boolArg('pub')) {
      await pub.get(context: PubContext.create, directory: directory.path, offline: boolArg('offline'));
      await project.ensureReadyForPlatformSpecificTooling(checkProjects: false);
    }

    if (templateContext['android'] as bool) {
      gradle.updateLocalProperties(project: project, requireAndroidSdk: false);
    }

    return generatedCount;
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
