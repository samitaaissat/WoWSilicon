import XCTest
@testable import WoWSiliconSwift

final class ModelCompatibilityTests: XCTestCase {
    func testUserPrefsDecodesFilesContainingRemovedKeys() throws {
        let json = """
        {
          "suppressed_update_version": "2.4.0",
          "show_terminal_normally": true,
          "enable_metal_hud": true,
          "enable_vanilla_tweaks": false,
          "auto_delete_wdb": false,
          "environment_variables": "A=B",
          "vanilla_tweaks_parameters": "--flag",
          "has_seen_wrath_warning": true
        }
        """

        let prefs = try JSONDecoder().decode(UserPrefs.self, from: Data(json.utf8))

        XCTAssertTrue(prefs.showTerminalNormally)
        XCTAssertTrue(prefs.enableMetalHud)
        XCTAssertFalse(prefs.enableVanillaTweaks)
        XCTAssertFalse(prefs.autoDeleteWdb)
        XCTAssertEqual(prefs.environmentVariables, "A=B")
        XCTAssertEqual(prefs.vanillaTweaksParameters, "--flag")
        // Added in 3.1: absent from every pre-existing prefs.json.
        XCTAssertFalse(prefs.enableMsync)
    }

    func testVersionSettingsDecodesFilesContainingRemovedSaveSudoPasswordKey() throws {
        let json = """
        {
          "enableMetalHud": true,
          "saveSudoPassword": true,
          "showTerminalNormally": true,
          "cursorSizeMultiplier": 4,
          "enableLibSiliconPatch": true
        }
        """

        let settings = try JSONDecoder().decode(VersionSettings.self, from: Data(json.utf8))

        XCTAssertTrue(settings.enableMetalHud)
        XCTAssertTrue(settings.showTerminalNormally)
        XCTAssertEqual(settings.cursorSizeMultiplier, 4)
        XCTAssertTrue(settings.enableLibSiliconPatch)
        // Added in 3.1: absent from every pre-existing versions.json.
        XCTAssertFalse(settings.enableMsync)
    }

    func testGameVersionDecodesAndRoundTripsV2CrossOverPath() throws {
        let json = """
        {
          "id": "vanillasilicon",
          "display_name": "VanillaSilicon (1.12.1)",
          "wow_version": "1.12.1",
          "game_path": "/Games/WoW",
          "crossover_path": "/Applications/CrossOver.app",
          "supports_vanilla_tweaks": true,
          "supports_dll_loading": true,
          "uses_rosetta_patching": true,
          "uses_divx_decoder_patch": false,
          "optimization_level": "high"
        }
        """

        let version = try JSONDecoder().decode(GameVersion.self, from: Data(json.utf8))
        XCTAssertEqual(version.crossOverPath, "/Applications/CrossOver.app")
        XCTAssertEqual(version.gamePath, "/Games/WoW")

        // Re-encode: the stored value must survive on disk (backward compat with v2).
        let reencoded = try JSONEncoder().encode(version)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertEqual(object["crossover_path"] as? String, "/Applications/CrossOver.app")

        let roundTripped = try JSONDecoder().decode(GameVersion.self, from: reencoded)
        XCTAssertEqual(roundTripped.crossOverPath, "/Applications/CrossOver.app")
    }

    func testVersionSettingsWithoutRendererDecodesToMTLD3D() throws {
        let json = #"{"enableMetalHud":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(VersionSettings.self, from: json)
        XCTAssertEqual(settings.renderer, .mtld3d)
        XCTAssertTrue(settings.enableMetalHud)
    }

    func testVersionSettingsRendererRoundTrip() throws {
        for renderer in RendererBackend.allCases {
            var settings = VersionSettings()
            settings.renderer = renderer
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(VersionSettings.self, from: data)
            XCTAssertEqual(decoded.renderer, renderer)
        }
    }

    /// An explicitly stored legacy choice keeps being honored — switching the
    /// default must never override what the user picked.
    func testVersionSettingsExplicitD9vkIsPreserved() throws {
        let json = #"{"renderer":"d9vk"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(VersionSettings.self, from: json)
        XCTAssertEqual(settings.renderer, .d9vk)
    }

    /// wined3d was removed in favor of mtld3d; a stored "wined3d" migrates to
    /// its replacement instead of silently landing on an unrelated backend.
    func testVersionSettingsWineD3DMigratesToMTLD3D() throws {
        let json = #"{"renderer":"wined3d","enableMetalHud":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(VersionSettings.self, from: json)
        XCTAssertEqual(settings.renderer, .mtld3d)
        XCTAssertTrue(settings.enableMetalHud)
    }

    /// Rollback safety: a versions.json written by a newer build with a renderer
    /// this build doesn't know must decode (falling back to the default), not
    /// fail the whole load and reset the user's versions.
    func testVersionSettingsUnknownRendererFallsBackToDefault() throws {
        let json = #"{"renderer":"metal4d","enableMetalHud":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(VersionSettings.self, from: json)
        XCTAssertEqual(settings.renderer, .mtld3d)
        XCTAssertTrue(settings.enableMetalHud)
    }
}
