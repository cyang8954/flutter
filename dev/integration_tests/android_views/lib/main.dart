import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'motion_events_page.dart';
import 'mutation_page.dart';
import 'page.dart';
import 'scroll_vew_nested_platform_view.dart';

final List<Page> _allPages = <Page>[
  const MotionEventsPage(),
  const MutationCompositionPage(),
  const ScrollViewNestedPlatformView(),
];

const String kPageNameMotionEvent = 'motion_event';
const String kPageMain = 'main';

final Home home = Home();

void main() {
  enableFlutterDriverExtension(handler: _handleMessage);
  runApp(MaterialApp(home: home));
}

class Home extends StatelessWidget {

  BuildContext _context;

  @override
  Widget build(BuildContext context) {
    _context = context;
    return Scaffold(
      body: ListView.builder(
        itemCount: _allPages.length,
        itemBuilder: (_, int index) => ListTile(
          title: Text(_allPages[index].title),
          key: _allPages[index].tileKey,
          onTap: () => _pushPage(context, _allPages[index]),
        ),
      ),
    );
  }

  void _pushPage(BuildContext context, Page page) {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
              body: page,
            )));
  }

  Future<String> handleMessage(String message) async {
    switch(message) {
      case 'target_platform':
        switch (Theme.of(_context).platform) {
          case TargetPlatform.iOS:
            return 'ios';
          case TargetPlatform.android:
            return 'android';
          default:
          return 'unsupported';
        }
    }
    return null;
  }
}

// Handles all the messages from the driver test and dispatch them.
//
// The format of the message should be '<page_name>|<command>'.
Future<String> _handleMessage(String message) async {
  final List<String> args = message.split('|');
  assert(args.length == 2);
  final String page = args.first;
  final String command = args.last;
  assert(page != command);
  switch(page) {
    case kPageMain: {
      return home.handleMessage(command);
    }
    case kPageNameMotionEvent: {
      return motionEventPageDriverDataHandler.handleMessage(command);
    }

  }
  return null;
}