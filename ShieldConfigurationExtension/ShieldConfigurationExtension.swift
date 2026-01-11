//
//  ShieldConfigurationExtension.swift
//  ShieldConfigurationExtension
//
//  Created by Cael Stewart on 2026-01-02.
//

import ManagedSettings
import ManagedSettingsUI
import UIKit

// Override the functions below to customize the shields used in various situations.
class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    
    // MARK: - Colors
    
    // Neon cyan for the primary action
    private let primaryHex = "#00F0FF"
    
    // Helper for creating UIColor from hex
    private func color(from hex: String) -> UIColor {
        var cString: String = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        
        if (cString.hasPrefix("#")) {
            cString.remove(at: cString.startIndex)
        }
        
        if ((cString.count) != 6) {
            return UIColor.systemCyan
        }
        
        var rgbValue: UInt64 = 0
        Scanner(string: cString).scanHexInt64(&rgbValue)
        
        return UIColor(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: CGFloat(1.0)
        )
    }
    
    // MARK: - Configuration
    
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        return commonConfiguration(appName: application.localizedDisplayName ?? "this app")
    }
    
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        return commonConfiguration(appName: application.localizedDisplayName ?? "this app")
    }
    
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        return commonConfiguration(appName: webDomain.domain ?? "this site")
    }
    
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        return commonConfiguration(appName: webDomain.domain ?? "this site")
    }
    
    // MARK: - Shield Design
    
    private func commonConfiguration(appName: String) -> ShieldConfiguration {
        let primaryColor = color(from: primaryHex)
        
        // Create the weightlifting icon from SF Symbols
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 60, weight: .medium)
        let icon = UIImage(systemName: "figure.strengthtraining.traditional", withConfiguration: iconConfig)
        
        return ShieldConfiguration(
            // nil = keeps Apple's beautiful frosted glass blur effect
            backgroundColor: nil,
            
            // Custom icon
            icon: icon,
            
            // Title
            title: ShieldConfiguration.Label(
                text: "Time's Up!",
                color: primaryColor
            ),
            
            // Subtitle - All messaging in one natural flow (like Opal's style)
            subtitle: ShieldConfiguration.Label(
                text: "You've hit your limit for \(appName).\n\nDiscipline is a muscle. Train it.\n\nOpen ScreenBlock to earn more time.",
                color: .white
            ),
            
            // Primary Button - Closes the app
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Close \(appName)",
                color: .black
            ),
            primaryButtonBackgroundColor: primaryColor
        )
    }
}
