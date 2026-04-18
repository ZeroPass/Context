import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rinf/rinf.dart';

import 'app/app_state.dart';
import 'src/bindings/bindings.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeRust(assignRustSignal);
  runApp(const ContextApp());
}

class ContextApp extends StatelessWidget {
  const ContextApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: Consumer<AppState>(
        builder: (context, state, _) {
          final lightScheme = ColorScheme.fromSeed(
            seedColor: Color(state.themeSeedColorValue),
            brightness: Brightness.light,
          );
          final darkScheme = ColorScheme.fromSeed(
            seedColor: Color(state.themeSeedColorValue),
            brightness: Brightness.dark,
          );
          late final Brightness brightness;
          late final ColorScheme scheme;
          if (state.themeAppearance == ThemeAppearance.light) {
            brightness = Brightness.light;
            scheme = lightScheme;
          } else if (state.themeAppearance == ThemeAppearance.sepia) {
            brightness = Brightness.light;
            scheme = _buildSepiaScheme(lightScheme);
          } else if (state.themeAppearance == ThemeAppearance.dim) {
            brightness = Brightness.dark;
            scheme = _buildDimScheme(lightScheme, darkScheme);
          } else {
            brightness = Brightness.dark;
            scheme = darkScheme;
          }
          return MaterialApp(
            title: 'Context',
            theme: ThemeData(
              brightness: brightness,
              colorScheme: scheme,
              useMaterial3: true,
              fontFamily: 'Oxanium',
              appBarTheme: AppBarTheme(
                titleTextStyle: TextStyle(
                  fontFamily: 'Oxanium',
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                  color: scheme.onSurface,
                ),
                toolbarTextStyle: TextStyle(
                  fontFamily: 'Oxanium',
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                  color: scheme.onSurface,
                ),
              ),
            ),
            home: const SelectionArea(child: HomeScreen()),
          );
        },
      ),
    );
  }

  ColorScheme _buildDimScheme(ColorScheme lightScheme, ColorScheme darkScheme) {
    Color lift(Color color, double amount) {
      return Color.alphaBlend(
        const Color(0xFFF8FAFC).withValues(alpha: amount),
        color,
      );
    }

    Color tint(Color base, Color tintColor, double amount) {
      return Color.alphaBlend(tintColor.withValues(alpha: amount), base);
    }

    Color soften(Color darkColor, Color lightColor, double amount) {
      return Color.lerp(darkColor, lightColor, amount)!;
    }

    Color liftedSurface(
      Color base, {
      required Color tintColor,
      required double liftAmount,
      required double tintAmount,
    }) {
      return tint(lift(base, liftAmount), tintColor, tintAmount);
    }

    return darkScheme.copyWith(
      primary: soften(darkScheme.primary, lightScheme.primary, 0.24),
      secondary: soften(darkScheme.secondary, lightScheme.secondary, 0.22),
      tertiary: soften(darkScheme.tertiary, lightScheme.tertiary, 0.22),
      primaryContainer: liftedSurface(
        darkScheme.primaryContainer,
        tintColor: lightScheme.primary,
        liftAmount: 0.16,
        tintAmount: 0.10,
      ),
      secondaryContainer: liftedSurface(
        darkScheme.secondaryContainer,
        tintColor: lightScheme.secondary,
        liftAmount: 0.14,
        tintAmount: 0.09,
      ),
      tertiaryContainer: liftedSurface(
        darkScheme.tertiaryContainer,
        tintColor: lightScheme.tertiary,
        liftAmount: 0.14,
        tintAmount: 0.09,
      ),
      surface: liftedSurface(
        darkScheme.surface,
        tintColor: lightScheme.primary,
        liftAmount: 0.16,
        tintAmount: 0.06,
      ),
      surfaceDim: liftedSurface(
        darkScheme.surfaceDim,
        tintColor: lightScheme.secondary,
        liftAmount: 0.12,
        tintAmount: 0.05,
      ),
      surfaceBright: liftedSurface(
        darkScheme.surfaceBright,
        tintColor: lightScheme.primary,
        liftAmount: 0.20,
        tintAmount: 0.08,
      ),
      surfaceContainerLowest: liftedSurface(
        darkScheme.surfaceContainerLowest,
        tintColor: lightScheme.primary,
        liftAmount: 0.10,
        tintAmount: 0.04,
      ),
      surfaceContainerLow: liftedSurface(
        darkScheme.surfaceContainerLow,
        tintColor: lightScheme.secondary,
        liftAmount: 0.12,
        tintAmount: 0.05,
      ),
      surfaceContainer: liftedSurface(
        darkScheme.surfaceContainer,
        tintColor: lightScheme.primary,
        liftAmount: 0.14,
        tintAmount: 0.06,
      ),
      surfaceContainerHigh: liftedSurface(
        darkScheme.surfaceContainerHigh,
        tintColor: lightScheme.secondary,
        liftAmount: 0.16,
        tintAmount: 0.07,
      ),
      surfaceContainerHighest: liftedSurface(
        darkScheme.surfaceContainerHighest,
        tintColor: lightScheme.tertiary,
        liftAmount: 0.18,
        tintAmount: 0.08,
      ),
      outline: lift(darkScheme.outline, 0.16),
      outlineVariant: lift(darkScheme.outlineVariant, 0.12),
      surfaceTint: soften(darkScheme.surfaceTint, lightScheme.surfaceTint, 0.22),
      inversePrimary: soften(
        darkScheme.inversePrimary,
        lightScheme.inversePrimary,
        0.22,
      ),
    );
  }

  ColorScheme _buildSepiaScheme(ColorScheme lightScheme) {
    Color mix(Color base, Color target, double amount) {
      return Color.lerp(base, target, amount)!;
    }

    const paper = Color(0xFFF3E7CF);
    const paperBright = Color(0xFFFBF5E8);
    const paperDeep = Color(0xFFE4D3B2);
    const paperMid = Color(0xFFEBDDC2);
    const ink = Color(0xFF2E241A);
    const softInk = Color(0xFF5C4B39);
    const outline = Color(0xFFA79274);
    const outlineSoft = Color(0xFFD4C2A6);
    const warmPrimary = Color(0xFFA56A2A);
    const warmSecondary = Color(0xFF8E7450);
    const warmTertiary = Color(0xFF7C6843);

    return lightScheme.copyWith(
      primary: mix(lightScheme.primary, warmPrimary, 0.18),
      secondary: mix(lightScheme.secondary, warmSecondary, 0.22),
      tertiary: mix(lightScheme.tertiary, warmTertiary, 0.20),
      primaryContainer: mix(lightScheme.primaryContainer, paperDeep, 0.42),
      secondaryContainer: mix(lightScheme.secondaryContainer, paperMid, 0.40),
      tertiaryContainer: mix(lightScheme.tertiaryContainer, paperDeep, 0.36),
      surface: paper,
      surfaceDim: mix(lightScheme.surfaceDim, paperDeep, 0.72),
      surfaceBright: paperBright,
      surfaceContainerLowest: paperBright,
      surfaceContainerLow: mix(lightScheme.surfaceContainerLow, paper, 0.70),
      surfaceContainer: mix(lightScheme.surfaceContainer, paperMid, 0.74),
      surfaceContainerHigh: mix(
        lightScheme.surfaceContainerHigh,
        paperDeep,
        0.78,
      ),
      surfaceContainerHighest: mix(
        lightScheme.surfaceContainerHighest,
        paperDeep,
        0.88,
      ),
      onSurface: ink,
      onSurfaceVariant: softInk,
      onPrimaryContainer: ink,
      onSecondaryContainer: ink,
      onTertiaryContainer: ink,
      outline: outline,
      outlineVariant: outlineSoft,
      shadow: const Color(0x331A120A),
      scrim: const Color(0x661A120A),
      surfaceTint: mix(lightScheme.surfaceTint, warmPrimary, 0.20),
      inverseSurface: const Color(0xFF2F251B),
      onInverseSurface: const Color(0xFFF7F0E2),
      inversePrimary: mix(
        lightScheme.inversePrimary,
        const Color(0xFFE5B16D),
        0.30,
      ),
    );
  }
}
