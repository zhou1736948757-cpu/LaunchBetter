import Foundation

/// Surface treatment selected from the current accessibility display options.
///
/// This is a view-facing semantic. A future owner may map `.translucent` to its
/// normal material and `.opaque` to a solid surface without putting AppKit or
/// layer objects in the policy layer.
enum AccessibilitySurfaceTreatment: Equatable, Sendable {
    case translucent
    case opaque
}

/// Whether a surface may depend on blur to remain legible.
enum AccessibilityBlurTreatment: Equatable, Sendable {
    case allowed
    case avoided
}

/// Boundary treatment for surfaces and controls.
enum AccessibilityBoundaryTreatment: Equatable, Sendable {
    case standard
    case emphasized
}

/// Foreground separation treatment for content placed on a surface.
enum AccessibilityForegroundSeparation: Equatable, Sendable {
    case standard
    case enhanced
}

/// Shadow treatment is deliberately independent from contrast treatment.
enum AccessibilityShadowTreatment: Equatable, Sendable {
    case preserveExistingWeight
}

/// Pure material semantics for a single accessibility environment snapshot.
///
/// Reduce Transparency selects a more opaque surface and avoids relying on
/// blur. Increase Contrast emphasizes boundaries and foreground separation,
/// while leaving shadow weight unchanged instead of applying a global shadow
/// boost. A view owner is responsible for mapping these values to its own
/// surface, border, and foreground layers.
struct AccessibilityMaterialPolicy: Equatable, Sendable {
    let surfaceTreatment: AccessibilitySurfaceTreatment
    let blurTreatment: AccessibilityBlurTreatment
    let boundaryTreatment: AccessibilityBoundaryTreatment
    let foregroundSeparation: AccessibilityForegroundSeparation
    let shadowTreatment: AccessibilityShadowTreatment
    let surfaceOpacity: Float

    var usesOpaqueSurface: Bool {
        surfaceTreatment == .opaque
    }

    var avoidsBlur: Bool {
        blurTreatment == .avoided
    }

    var emphasizesBoundary: Bool {
        boundaryTreatment == .emphasized
    }

    var enhancesForegroundSeparation: Bool {
        foregroundSeparation == .enhanced
    }

    init(snapshot: MotionEnvironmentSnapshot) {
        if snapshot.reduceTransparency {
            surfaceTreatment = .opaque
            blurTreatment = .avoided
            surfaceOpacity = 0.96
        } else {
            surfaceTreatment = .translucent
            blurTreatment = .allowed
            surfaceOpacity = 0.78
        }

        boundaryTreatment = snapshot.increaseContrast ? .emphasized : .standard
        foregroundSeparation = snapshot.increaseContrast ? .enhanced : .standard
        shadowTreatment = .preserveExistingWeight
    }
}
