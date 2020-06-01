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
  PluginCommand({ bool verboseHelp = false }) {
    addSubcommand(PluginCreateCommand(verboseHelp: verboseHelp));
    addSubcommand(PluginAddPlatformsCommand(verboseHelp: verboseHelp));
  }

  @override
  final String name = 'plugin';

  @override
  final String description = 'Commands related to Flutter plugins';

  @override
  Future<FlutterCommandResult> runCommand() async => null;
}