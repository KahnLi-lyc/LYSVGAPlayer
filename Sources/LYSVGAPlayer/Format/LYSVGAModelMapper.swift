import Foundation

enum LYSVGAModelMapper {
    static func rect(x: Float, y: Float, width: Float, height: Float) -> LYSVGARect {
        LYSVGARect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }

    static func transform(_ value: Com_Opensource_Svga_Transform) -> LYSVGATransform {
        LYSVGATransform(
            a: Double(value.a), b: Double(value.b), c: Double(value.c),
            d: Double(value.d), tx: Double(value.tx), ty: Double(value.ty)
        )
    }

    static func color(_ value: Com_Opensource_Svga_ShapeEntity.ShapeStyle.RGBAColor?) -> LYSVGAColor? {
        guard let value else { return nil }
        return LYSVGAColor(
            red: Double(value.r), green: Double(value.g),
            blue: Double(value.b), alpha: Double(value.a)
        )
    }
}
