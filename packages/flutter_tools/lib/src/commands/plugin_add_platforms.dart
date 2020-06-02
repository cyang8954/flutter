// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'package:args/args.dart';
import 'package:yaml/yaml.dart';

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

class PluginAddPlatformsCommand extends FlutterCommand with PluginCommandMixin {
  PluginAddPlatformsCommand() {
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
      help:
          "Also add a flutter_driver dependency and generate a sample 'flutter drive' test.",
    );
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
      CustomDimensions.commandCreateAndroidLanguage:
          stringArg('android-language'),
      CustomDimensions.commandCreateIosLanguage: stringArg('ios-language'),
    };
  }

  // Lazy-initialize the net utilities with values from the context.
  Net _cachedNet;
  Net get _net => _cachedNet ??= Net(
        httpClientFactory:
            context.get<HttpClientFactory>() ?? () => HttpClient(),
        logger: globals.logger,
        platform: globals.platform,
      );

  bool _isPluginProject(Directory projectDir) {
    final File metadataFile = globals.fs
        .file(globals.fs.path.join(projectDir.absolute.path, '.metadata'));
    final FlutterProjectMetadata projectMetadata =
        FlutterProjectMetadata(metadataFile, globals.logger);
    return projectMetadata.projectType == FlutterProjectType.plugin;
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    final Map<String, dynamic> templateContext =
        await validateArgsAndCreateTemplate(argParser);

    final Directory projectDir = globals.fs.directory(argResults.rest.first);
    if (!_isPluginProject(projectDir)) {
      throwToolExit('The current directory is not a Flutter plugin directory',
          exitCode: 2);
    }
    final FlutterProject project = FlutterProject.fromDirectory(projectDir);
    
    final String projectDirPath =
        globals.fs.path.normalize(projectDir.absolute.path);

    final Directory relativeDir = globals.fs.directory(projectDirPath);
    int generatedFileCount = 0;
    final bool overwrite = boolArg('overwrite');
    final List<String> platforms = stringsArg('platforms');
    generatedFileCount += await _addPlatforms(
        relativeDir, templateContext, platforms,
        overwrite: overwrite);

    globals.printStatus('Wrote $generatedFileCount files.');
    globals.printStatus('\nAll done!');

    const String application = 'application';

    // Run doctor; tell the user the next steps.
    final FlutterProject app =
        project.hasExampleApp ? project.example : project;
    final String relativeAppPath =
        globals.fs.path.normalize(globals.fs.path.relative(app.directory.path));
    final String relativeAppMain =
        globals.fs.path.join(relativeAppPath, 'lib', 'main.dart');
    final String relativePluginPath =
        globals.fs.path.normalize(globals.fs.path.relative(projectDirPath));
    final String relativePluginMain = globals.fs.path
        .join(relativePluginPath, 'lib', '${project.manifest.appName}.dart');
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
      // Warn about unstable templates. This should be last so that it's not
      // lost among the other output.
      if (platforms.contains('linux')) {
        globals.printStatus('');
        globals.printStatus(
            'WARNING: The Linux tooling and APIs are not yet stable. '
            'You will likely need to re-create the "linux" directory after future '
            'Flutter updates.');
      }
      if (platforms.contains('windows')) {
        globals.printStatus('');
        globals.printStatus(
            'WARNING: The Windows tooling and APIs are not yet stable. '
            'You will likely need to re-create the "windows" directory after future '
            'Flutter updates.');
      }
    }

    return FlutterCommandResult.success();
  }

  Future<int> _addPlatforms(Directory directory,
      Map<String, dynamic> templateContext, final List<String> platforms,
      {bool overwrite = false}) async {
    int generatedCount = 0;
    // Add files to the plugin.
    generatedCount += await renderTemplate('plugin', directory, templateContext,
        overwrite: overwrite);
    if (boolArg('pub')) {
      await pub.get(
        context: PubContext.createPlugin,
        directory: directory.path,
        offline: boolArg('offline'),
      );
    }
    // Add files to example app.
    final FlutterProject project = FlutterProject.fromDirectory(directory);

    final String exampleProjectName = project.manifest.appName + '_example';

    final bool isAndroid = platforms.contains('android');
    final bool isIOS = platforms.contains('ios');
    if (isAndroid || isIOS) {
      final String organization = templateContext['organization'] as String;
      print(organization);
      if (isAndroid) {
        if (platforms.contains('android')) {
          gradle.updateLocalProperties(
              project: project, requireAndroidSdk: false);
          // The below 2 statements order matters and cannot be swapped.
          templateContext['androidPluginIdentifer'] =
              templateContext['androidIdentifier'] as String;
          templateContext['androidIdentifier'] =
              createAndroidIdentifier(organization, exampleProjectName);
        }
      }
      if (isIOS) {
        templateContext['iosIdentifier'] =
            createUTIIdentifier(organization, exampleProjectName);
      }
    }
    templateContext['pluginProjectName'] = project.manifest.appName;
    generatedCount += await _generateApp(
        project.example.directory, templateContext, platforms,
        overwrite: overwrite);

    await _updatePubspec(directory.path, platforms, templateContext['pluginClass'] as String, templateContext['androidPluginIdentifer'] as String);
    return generatedCount;
  }

  Future<int> _generateApp(
      Directory directory, Map<String, dynamic> templateContext, final List<String> platforms,
      {bool overwrite = false}) async {
    int generatedCount = 0;
    generatedCount += await renderTemplate('app', directory, templateContext,
        overwrite: overwrite);
    final FlutterProject project = FlutterProject.fromDirectory(directory);
    if (platforms.contains('android')) {
      generatedCount += _injectGradleWrapper(project);
    }

    if (boolArg('with-driver-test')) {
      final Directory testDirectory = directory.childDirectory('test_driver');
      generatedCount += await renderTemplate(
          'driver', testDirectory, templateContext,
          overwrite: overwrite);
    }

    if (boolArg('pub')) {
      await pub.get(
          context: PubContext.create,
          directory: directory.path,
          offline: boolArg('offline'));
      await project.ensureReadyForPlatformSpecificTooling(checkProjects: false);
    }
    if (platforms.contains('android')) {
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

  Future<void> _updatePubspec(String projectDir, final List<String> platforms, String pluginClass, String androidIdentifier) async {
    final String pubspecPath = globals.fs.path.join(projectDir, 'pubspec.yaml');
    final YamlMap pubspec = loadYaml(globals.fs.file(pubspecPath).readAsStringSync()) as YamlMap;
    final bool isPubspecValid = _validatePubspec(pubspec);
    if (!isPubspecValid) {
      throwToolExit('Invalid flutter plugin `pubspec.yaml` file.',
          exitCode: 2);
    }
    try {
      // The format of the updated pubspec might not be preserved.
      // TODO(cyanglaz): This below logic is fragile as we are searching for and replacing `platform:` in the file.
      // There might be situations where user had a different `platforms:` in the pubspec.yaml that is not what we wanted.
      // For example, a comment.
      final List<String> existingPlatforms = _getExistingPlatforms(pubspec);
      final List<String> platformsToAdd = platforms;
      platformsToAdd.removeWhere((String platform) => existingPlatforms.contains(platform));
      print(platformsToAdd);
      final File pubspecFile = globals.fs.file(pubspecPath);
      final List<String> fileContents = pubspecFile.readAsLinesSync();
      int index;
      String frontSpaces;
      for (int i = 0; i < fileContents.length; i ++) {
        // Find the line of `platforms:`
        final String line = fileContents[i];
        if (line.contains('platforms:')) {
          final String lastLine = fileContents[i-1];
          if (!lastLine.contains('plugin:')) {
            continue;
          }
          // Find how many spaces are in front of the `platforms`.
          frontSpaces = line.split('platforms:').first;
          index = i + 1;
          break;
        }
      }
      for (final String platform in platformsToAdd) {
        fileContents.insert(index, frontSpaces + '  $platform:');
        index ++;
        fileContents.insert(index, frontSpaces + '    pluginClass: $pluginClass');
        index ++;
        if (platform == 'android') {
          fileContents.insert(index, frontSpaces + '    package: $androidIdentifier');
        }
      }
      String writeString = fileContents.join('\n');
      pubspecFile.writeAsStringSync(writeString);
      // final String fileContents = pubspecFile.readAsStringSync();
      // String newPlatformList = 'platforms:\n';
      // for (final String platform in platformsToAdd) {
      //   newPlatformList += ' $platform:\n';
      //   newPlatformList += '  pluginClass: $pluginClass\n';
      //   if (platform == 'android') {
      //     newPlatformList += '  package: $androidIdentifier\n';
      //   }
      // }
      // String newContent = fileContents.replaceFirst('platforms:\n', newPlatformList);
      // print(fileContents);
      // print(newPlatformList);
      // pubspecFile.writeAsStringSync(newContent);
    } on FileSystemException catch (e) {
      throwToolExit(e.message, exitCode: 2);
    }
  }

  bool _validatePubspec(YamlMap pubspec) {
    return _getPlatformsYamlMap(pubspec) != null;
  }

  List<String> _getExistingPlatforms(YamlMap pubspec) {
    final YamlMap platformsMap = _getPlatformsYamlMap(pubspec);
    return platformsMap.keys.cast<String>().toList();
  }

  YamlMap _getPlatformsYamlMap(YamlMap pubspec) {
    if (pubspec == null) {
       return null;
    }
    final YamlMap flutterConfig = pubspec['flutter'] as YamlMap;
    if (flutterConfig == null) {
      return null;
    }
    final YamlMap pluginConfig = flutterConfig['plugin'] as YamlMap;
    if (pluginConfig == null) {
      return null;
    }
    return pluginConfig['platforms'] != null ? pluginConfig['platforms'] as YamlMap: null;
  }

  void _addPlatformToYaml(YamlMap platforms, String platform) {

  }
}
