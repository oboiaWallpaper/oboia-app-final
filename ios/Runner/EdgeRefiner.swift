// EdgeRefiner.swift
//
// Standalone helper for cleaning up vertex alpha boundaries.
// No AR session changes, no material rewriting, no side effects.
// Pure functions: take alpha + vertex positions in, return cleaned alpha out.
//
// New file. Add to: ios/Runner/EdgeRefiner.swift
//
// WallpaperARView calls into this in 3 places (search for "EdgeRefiner." in WallpaperARView):
//   1. After applyLasso → snapToLassoLines() for ruler-straight lasso edges
//   2. After applyGaussianBrush (stroke end) → smoothBoundary() to remove fuzz
//   3. Before buildAlphaGeo if needed → morphologicalClean() for hole filling

import simd
import Foundation

enum EdgeRefiner {

    // ════════════════════════════════════════════════════════════
    // TECHNIQUE 1: Snap to lasso lines
    //
    // After a lasso polygon cut, vertices near the polygon's edges
    // get re-classified based on their PERPENDICULAR distance to the
    // nearest line segment in 3D space (not screen space, not triangle space).
    //
    // This bypasses the LiDAR triangle constraint and produces edges
    // that follow the actual line the user drew.
    // ════════════════════════════════════════════════════════════

    /// Snap vertices near lasso edges to align with the 3D polygon lines.
    /// - Parameters:
    ///   - alpha: current per-vertex alpha (modified by lasso pointInPolygon)
    ///   - vertexPositions: 3D world positions of each vertex
    ///   - polygonWorldPoints: 3D world points of the lasso polygon (in order)
    ///   - mode: "erase" or "paint" — what the lasso just did
    ///   - snapDistance: meters — vertices within this band get re-evaluated (default 6cm)
    /// - Returns: cleaned alpha array
    static func snapToLassoLines(
        alpha: [Float],
        vertexPositions: [SIMD3<Float>],
        polygonWorldPoints: [SIMD3<Float>],
        mode: String,
        snapDistance: Float = 0.06
    ) -> [Float] {
        guard polygonWorldPoints.count >= 3, alpha.count == vertexPositions.count else {
            return alpha
        }

        let isErase = (mode == "erase")
        var result = alpha

        for (vi, vPos) in vertexPositions.enumerated() {
            // Find perpendicular distance to nearest polygon line segment
            var minDist: Float = .greatestFiniteMagnitude
            for i in 0..<polygonWorldPoints.count {
                let a = polygonWorldPoints[i]
                let b = polygonWorldPoints[(i + 1) % polygonWorldPoints.count]
                let d = distanceFromPointToSegment3D(p: vPos, a: a, b: b)
                if d < minDist { minDist = d }
            }

            // Only act on vertices within the snap band
            guard minDist <= snapDistance else { continue }

            // Determine which side of the boundary this vertex is on
            // by checking if it's inside the polygon (project onto polygon's best-fit plane)
            let inside = pointInPolygon3D(p: vPos, polygon: polygonWorldPoints)

            // Snap decision: vertices inside polygon get the lasso effect cleanly,
            // outside vertices keep their state — but vertices RIGHT on the line
            // (very small minDist) take a hard binary value based on inside/outside
            let snapThreshold: Float = snapDistance * 0.5
            if minDist <= snapThreshold {
                if inside {
                    result[vi] = isErase ? 0.0 : 1.0
                }
                // Outside vertices in the band are left alone — preserves what was there
            }
        }
        return result
    }

    // ════════════════════════════════════════════════════════════
    // TECHNIQUE 2: Boundary smoothing
    //
    // For vertices that lie on an alpha=0/1 transition, take the
    // average alpha of their neighbors. This kills lone vertex spikes
    // and small zigzags on the edge.
    // ════════════════════════════════════════════════════════════

    /// Build vertex adjacency from triangle indices.
    /// Each vertex maps to the set of vertices it shares an edge with.
    static func buildAdjacency(
        vertexCount: Int,
        triangleIndices: [UInt32]
    ) -> [[Int]] {
        var adj = Array(repeating: Set<Int>(), count: vertexCount)
        let triCount = triangleIndices.count / 3
        for t in 0..<triCount {
            let a = Int(triangleIndices[t * 3])
            let b = Int(triangleIndices[t * 3 + 1])
            let c = Int(triangleIndices[t * 3 + 2])
            if a < vertexCount && b < vertexCount && c < vertexCount {
                adj[a].insert(b); adj[a].insert(c)
                adj[b].insert(a); adj[b].insert(c)
                adj[c].insert(a); adj[c].insert(b)
            }
        }
        return adj.map { Array($0) }
    }

    /// Smooth alpha values along the 0/1 boundary.
    /// Only modifies vertices that are on the boundary (have at least one
    /// neighbor with different alpha). Interior and fully-hidden areas untouched.
    static func smoothBoundary(
        alpha: [Float],
        adjacency: [[Int]],
        iterations: Int = 2
    ) -> [Float] {
        guard alpha.count == adjacency.count else { return alpha }
        var current = alpha
        for _ in 0..<iterations {
            var next = current
            for vi in 0..<current.count {
                let neighbors = adjacency[vi]
                guard !neighbors.isEmpty else { continue }

                // Check if this vertex is on the boundary
                let myAlpha = current[vi]
                var onBoundary = false
                for n in neighbors {
                    if abs(current[n] - myAlpha) > 0.1 { onBoundary = true; break }
                }
                guard onBoundary else { continue }

                // Average with neighbors (50% self, 50% neighbors mean)
                var sum: Float = 0
                for n in neighbors { sum += current[n] }
                let neighborMean = sum / Float(neighbors.count)
                next[vi] = myAlpha * 0.5 + neighborMean * 0.5
            }
            current = next
        }
        return current
    }

    // ════════════════════════════════════════════════════════════
    // TECHNIQUE 3: Morphological cleanup
    //
    // Fills small holes and removes isolated spikes by treating alpha
    // as a binary mask and applying dilate+erode (closing) operations.
    // ════════════════════════════════════════════════════════════

    /// Fill 1-vertex holes and remove 1-vertex spikes.
    /// Threshold-based: vertex flips if majority of neighbors disagree.
    static func morphologicalClean(
        alpha: [Float],
        adjacency: [[Int]],
        threshold: Float = 0.5
    ) -> [Float] {
        guard alpha.count == adjacency.count else { return alpha }
        var result = alpha
        for vi in 0..<alpha.count {
            let neighbors = adjacency[vi]
            guard neighbors.count >= 3 else { continue }

            let myBin: Float = alpha[vi] >= threshold ? 1.0 : 0.0
            var disagreeCount = 0
            for n in neighbors {
                let nBin: Float = alpha[n] >= threshold ? 1.0 : 0.0
                if nBin != myBin { disagreeCount += 1 }
            }
            // If 2/3 or more of neighbors disagree, flip this vertex
            if disagreeCount * 3 >= neighbors.count * 2 {
                result[vi] = myBin > 0.5 ? 0.0 : 1.0
            }
        }
        return result
    }

    // ════════════════════════════════════════════════════════════
    // 3D GEOMETRY HELPERS
    // ════════════════════════════════════════════════════════════

    /// Perpendicular distance from point P to line segment AB in 3D
    static func distanceFromPointToSegment3D(p: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>) -> Float {
        let ab = b - a
        let ap = p - a
        let abLengthSq = simd_dot(ab, ab)
        if abLengthSq < 1e-8 { return simd_length(ap) }
        var t = simd_dot(ap, ab) / abLengthSq
        t = max(0.0, min(1.0, t))
        let closest = a + ab * t
        return simd_length(p - closest)
    }

    /// Test if a 3D point is "inside" a 3D polygon by projecting onto the
    /// polygon's best-fit plane and doing a 2D point-in-polygon test.
    static func pointInPolygon3D(p: SIMD3<Float>, polygon: [SIMD3<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }

        // Compute polygon's best-fit normal via Newell's method
        var normal = SIMD3<Float>(0, 0, 0)
        for i in 0..<polygon.count {
            let curr = polygon[i]
            let next = polygon[(i + 1) % polygon.count]
            normal.x += (curr.y - next.y) * (curr.z + next.z)
            normal.y += (curr.z - next.z) * (curr.x + next.x)
            normal.z += (curr.x - next.x) * (curr.y + next.y)
        }
        let nLen = simd_length(normal)
        guard nLen > 1e-6 else { return false }
        normal = normal / nLen

        // Pick the two largest components of normal to determine projection plane
        let absN = SIMD3<Float>(abs(normal.x), abs(normal.y), abs(normal.z))
        let dropAxis: Int
        if absN.x >= absN.y && absN.x >= absN.z { dropAxis = 0 }
        else if absN.y >= absN.z { dropAxis = 1 }
        else { dropAxis = 2 }

        // Project polygon and point onto the 2D plane (drop the dropAxis)
        func project(_ v: SIMD3<Float>) -> (Float, Float) {
            switch dropAxis {
            case 0: return (v.y, v.z)
            case 1: return (v.x, v.z)
            default: return (v.x, v.y)
            }
        }

        let p2d = project(p)
        let poly2d = polygon.map { project($0) }

        // Ray casting algorithm
        var inside = false
        var j = poly2d.count - 1
        for i in 0..<poly2d.count {
            let pi = poly2d[i]
            let pj = poly2d[j]
            if (pi.1 > p2d.1) != (pj.1 > p2d.1) {
                let xCross = pi.0 + (p2d.1 - pi.1) / (pj.1 - pi.1) * (pj.0 - pi.0)
                if p2d.0 < xCross { inside = !inside }
            }
            j = i
        }
        return inside
    }
}
