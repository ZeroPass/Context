import 'dart:typed_data';

import 'package:context/src/bindings/bindings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decodes bytes produced by the Rust-side `wire_order_tests::sentinel_state`
/// in native/hub/src/signals/mod.rs. Bincode is field-order sensitive and the
/// UiState Dart binding is hand-maintained, so this pins the cross-language
/// layout: if either side reorders or adds a field without updating both,
/// this test or the Rust one fails before a broken build ships.
void main() {
  test('UiState Dart binding decodes the Rust wire fixture', () {
    const hex =
        '341200000000000001010100000000000000730001000000000000007001000000'
        '000000006901000000000000007701000000000000006301000000000000006b01'
        '000000000000006f01000000000000007101000000000000006d01000000000000'
        '007a00010100000000000000720200000000000000636100010102000000000000'
        '0063730002000000000000006d610102000000000000006d6f0000010200000000'
        '0000006d6502000000000000007a61010102000000000000007a7300';
    final bytes = Uint8List.fromList([
      for (var index = 0; index < hex.length; index += 2)
        int.parse(hex.substring(index, index + 2), radix: 16),
    ]);

    final state = UiState.bincodeDeserialize(bytes);

    expect(state.themeSeedColorValue, 0x1234);
    expect(state.busy, isTrue);
    expect(state.status, 's');
    expect(state.lastError, isNull);
    expect(state.sessionsMarkdownPath, 'p');
    expect(state.itemsJson, 'i');
    expect(state.warningsJson, 'w');
    expect(state.recentCodexJson, 'c');
    expect(state.recentKimiJson, 'k');
    expect(state.recentOpencodeJson, 'o');
    expect(state.recentQwenJson, 'q');
    expect(state.recentMuseJson, 'm');
    expect(state.recentZcodeJson, 'z');
    expect(state.recentBusy, isFalse);
    expect(state.recentStatus, 'r');
    expect(state.codexAccountsJson, 'ca');
    expect(state.codexActiveAccount, isNull);
    expect(state.codexAccountBusy, isTrue);
    expect(state.codexAccountStatus, 'cs');
    expect(state.codexAccountError, isNull);
    expect(state.museAccountsJson, 'ma');
    expect(state.museActiveAccount, 'mo');
    expect(state.museAccountBusy, isFalse);
    expect(state.museAccountStatus, isNull);
    expect(state.museAccountError, 'me');
    expect(state.zcodeAccountsJson, 'za');
    expect(state.zcodeAccountBusy, isTrue);
    expect(state.zcodeAccountStatus, 'zs');
    expect(state.zcodeAccountError, isNull);
  });
}
