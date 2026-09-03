import simd

public struct Color {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float
    
    public init(red: Float, green: Float, blue: Float, alpha: Float = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    
    public init(_ color: simd_float3, alpha: Float = 1.0) {
        self.red = color.x
        self.green = color.y
        self.blue = color.z
        self.alpha = alpha
    }

    public var rgb: simd_float3 {
        simd_float3(red, green, blue)
    }
    
    public var rgba: simd_float4 {
        simd_float4(red, green, blue, alpha)
    }
    
    public func opacity(_ alpha: Float) -> Color {
        .init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Color: Equatable { }
extension Color: Sendable { }

extension Color {
    public static var black: Color {
        .init(red: 0.0, green: 0.0, blue: 0.0)
    }
    
    public static var white: Color {
        .init(red: 1.0, green: 1.0, blue: 1.0)
    }
    
    public static var red: Color {
        .init(red: 1.0, green: 0.0, blue: 0.0)
    }
    
    public static var green: Color {
        .init(red: 0.0, green: 1.0, blue: 0.0)
    }
    
    public static var blue: Color {
        .init(red: 0.0, green: 0.0, blue: 1.0)
    }
    
    public static var yellow: Color {
        .init(red: 1.0, green: 1.0, blue: 0.0)
    }
    
    public static var orange: Color {
        .init(red: 1.0, green: 0.5, blue: 0.0)
    }
    
    public static var purple: Color {
        .init(red: 0.5, green: 0.0, blue: 1.0)
    }
    
    public static var pink: Color {
        .init(red: 1.0, green: 0.0, blue: 1.0)
    }
    
    public static var brown: Color {
        .init(red: 0.6, green: 0.3, blue: 0.0)
    }
    
    public static var gray: Color {
        .init(red: 0.5, green: 0.5, blue: 0.5)
    }
    
    public static var cyan: Color {
        .init(red: 0.0, green: 1.0, blue: 1.0)
    }
    
    public static var indigo: Color {
        .init(red: 0.3, green: 0.0, blue: 0.5)
    }
    
    public static var mint: Color {
        .init(red: 0.0, green: 1.0, blue: 0.5)
    }
    
    public static var teal: Color {
        .init(red: 0.0, green: 0.5, blue: 0.5)
    }
    
    public static var clear: Color {
        .init(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    }
}
