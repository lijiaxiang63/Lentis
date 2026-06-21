// LentisResources.swift
// Lentis
//
// SwiftPM test/CLI builds locate resources through Bundle.module. A staged
// macOS app keeps the generated resource bundle in the platform-standard
// Contents/Resources directory so code signing can seal it correctly.

import Foundation

extension Bundle {
    static var lentisResources: Bundle {
        if let resources = Bundle.main.resourceURL,
           let staged = Bundle(url: resources.appendingPathComponent("Lentis_Lentis.bundle")) {
            return staged
        }
        return .module
    }
}
