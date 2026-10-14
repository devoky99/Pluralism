import Foundation

/// Schreibt RFB-Rechtecke in einen Pixelspeicher (4 Bytes pro Pixel).
/// Arbeitet direkt auf Zeigern, damit die App in den Speicher eines CGContext schreiben kann.
public enum RFBFramebufferWriter {
    /// Kopiert Rohpixel (Breite w, Höhe h, dicht gepackt) an Position (x, y).
    /// Alles außerhalb des Ziels wird abgeschnitten.
    public static func blitRaw(_ pixels: [UInt8], rect: RFBRect,
                               into destination: UnsafeMutableRawPointer,
                               bytesPerRow: Int, width: Int, height: Int, bytesPerPixel: Int = 4) {
        guard rect.width > 0, rect.height > 0 else { return }
        let x0 = max(0, rect.x)
        let y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width)
        let y1 = min(height, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return }
        let rowBytes = (x1 - x0) * bytesPerPixel
        let sourceRowBytes = rect.width * bytesPerPixel
        guard pixels.count >= sourceRowBytes * rect.height else { return }
        pixels.withUnsafeBytes { sourceBuffer in
            guard let base = sourceBuffer.baseAddress else { return }
            for row in y0..<y1 {
                let sourceOffset = (row - rect.y) * sourceRowBytes + (x0 - rect.x) * bytesPerPixel
                let destinationOffset = row * bytesPerRow + x0 * bytesPerPixel
                memcpy(destination + destinationOffset, base + sourceOffset, rowBytes)
            }
        }
    }

    /// Verschiebt einen Bereich innerhalb des Bildes (CopyRect). Überlappung ist erlaubt.
    public static func copyRect(sourceX: Int, sourceY: Int, rect: RFBRect,
                                in buffer: UnsafeMutableRawPointer,
                                bytesPerRow: Int, width: Int, height: Int, bytesPerPixel: Int = 4) {
        let w = min(rect.width, width - max(rect.x, sourceX))
        let h = min(rect.height, height - max(rect.y, sourceY))
        guard w > 0, h > 0, rect.x >= 0, rect.y >= 0, sourceX >= 0, sourceY >= 0 else { return }
        let rowBytes = w * bytesPerPixel
        // Von unten nach oben kopieren, wenn das Ziel unter der Quelle liegt.
        let rows: [Int] = rect.y > sourceY ? Array((0..<h).reversed()) : Array(0..<h)
        for r in rows {
            let from = (sourceY + r) * bytesPerRow + sourceX * bytesPerPixel
            let to = (rect.y + r) * bytesPerRow + rect.x * bytesPerPixel
            memmove(buffer + to, buffer + from, rowBytes)
        }
    }
}
