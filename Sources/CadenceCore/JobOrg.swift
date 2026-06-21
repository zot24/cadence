import Foundation

/// Derives a human-friendly vendor/organization name from a job's reverse-DNS
/// label (e.g. `com.docker.socket` → "Docker", `com.adobe.ARMDC.*` → "Adobe"),
/// for grouping the job list. Pure + testable.
public enum JobOrg {
    public static let other = "Other"

    /// Leading components that are domain TLDs/namespaces, so the *next*
    /// component is the vendor.
    static let tlds: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "app", "co", "edu", "gov",
        "at", "uk", "de", "me", "xyz", "tech", "sh", "cloud", "systems", "fr", "nl", "ch",
    ]

    /// Canonical display names for vendors whose slug doesn't title-case cleanly.
    static let friendly: [String: String] = [
        "adobe": "Adobe", "docker": "Docker", "microsoft": "Microsoft", "google": "Google",
        "apple": "Apple", "github": "GitHub", "openvpn": "OpenVPN", "teamviewer": "TeamViewer",
        "orbstack": "OrbStack", "hermes": "Hermes", "obdev": "Objective Development",
        "paragon-software": "Paragon Software", "jetbrains": "JetBrains", "homebrew": "Homebrew",
        "1password": "1Password", "amazon": "Amazon", "mongodb": "MongoDB", "postgresql": "PostgreSQL",
        "vmware": "VMware", "zoom": "Zoom", "spotify": "Spotify", "dropbox": "Dropbox",
    ]

    public static func organization(forLabel label: String) -> String {
        let parts = label.split(separator: ".").map(String.init)
        guard parts.count >= 2, tlds.contains(parts[0].lowercased()) else { return other }
        let key = parts[1].lowercased()
        if let f = friendly[key] { return f }
        guard !key.isEmpty else { return other }
        // Title-case the slug, splitting hyphens (e.g. "paragon-software").
        return key.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}
