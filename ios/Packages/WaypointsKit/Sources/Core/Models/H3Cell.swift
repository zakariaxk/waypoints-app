import Foundation

/// Decodes an H3 cell index to its centre coordinate (MAP-7). The wire `CellAggregate`
/// carries only the index, so the centre is derived client-side. Port of `cellToLatLng`
/// from H3 v4.5.0 (Apache-2.0, github.com/uber/h3) — the same source the gateway's
/// h3-go dependency links.
enum H3Cell {

    // MARK: Index bits (h3Index.h)

    static func resolution(_ h: UInt64) -> Int { Int((h >> 52) & 0xF) }
    static func baseCell(_ h: UInt64) -> Int { Int((h >> 45) & 0x7F) }
    static func digit(_ h: UInt64, _ res: Int) -> Int { Int((h >> UInt64((15 - res) * 3)) & 7) }

    static func setDigit(_ h: inout UInt64, _ res: Int, _ d: Int) {
        let shift = UInt64((15 - res) * 3)
        h = (h & ~(7 << shift)) | (UInt64(d) << shift)
    }

    static func isClassIII(_ res: Int) -> Bool { res % 2 == 1 }
    static func isPentagon(_ baseCell: Int) -> Bool { baseCells[baseCell].pentagon }

    static func leadingNonZeroDigit(_ h: UInt64) -> Int {
        guard resolution(h) > 0 else { return 0 }
        for r in 1...resolution(h) where digit(h, r) != 0 { return digit(h, r) }
        return 0
    }

    /// Rotate every digit of the index 60° clockwise (`_h3Rotate60cw`).
    static func rotate60cw(_ h: UInt64) -> UInt64 {
        var h = h
        guard resolution(h) > 0 else { return h }
        for r in 1...resolution(h) {
            setDigit(&h, r, rotateDigit60cw(digit(h, r)))
        }
        return h
    }

    static func rotateDigit60cw(_ d: Int) -> Int {
        switch d { case 1: 3; case 3: 2; case 2: 6; case 6: 4; case 4: 5; case 5: 1; default: d }
    }

    // MARK: IJK coordinates (coordijk.h)

    struct IJK: Equatable {
        var i = 0, j = 0, k = 0

        mutating func normalize() {
            if i < 0 { j -= i; k -= i; i = 0 }
            if j < 0 { i -= j; k -= j; j = 0 }
            if k < 0 { i -= k; j -= k; k = 0 }
            let m = Swift.min(i, j, k)
            if m > 0 { i -= m; j -= m; k -= m }
        }

        static func + (a: IJK, b: IJK) -> IJK { IJK(i: a.i + b.i, j: a.j + b.j, k: a.k + b.k) }
        static func - (a: IJK, b: IJK) -> IJK { IJK(i: a.i - b.i, j: a.j - b.j, k: a.k - b.k) }
        static func * (a: IJK, f: Int) -> IJK { IJK(i: a.i * f, j: a.j * f, k: a.k * f) }

        /// Unit vectors for digits 0–6 (`UNIT_VECS`).
        static let unitVecs = [
            IJK(i: 0, j: 0, k: 0), IJK(i: 0, j: 0, k: 1), IJK(i: 0, j: 1, k: 0), IJK(i: 0, j: 1, k: 1),
            IJK(i: 1, j: 0, k: 0), IJK(i: 1, j: 0, k: 1), IJK(i: 1, j: 1, k: 0),
        ]

        mutating func neighbor(_ digit: Int) {
            guard digit > 0 && digit < 7 else { return }
            self = (self + Self.unitVecs[digit]).normalized()
        }

        mutating func rotate60ccw() {
            self = (IJK(i: 1, j: 1, k: 0) * i + IJK(i: 0, j: 1, k: 1) * j + IJK(i: 1, j: 0, k: 1) * k).normalized()
        }

        mutating func rotate60cw() {
            self = (IJK(i: 1, j: 0, k: 1) * i + IJK(i: 1, j: 1, k: 0) * j + IJK(i: 0, j: 1, k: 1) * k).normalized()
        }

        /// Centre of the hex under this hex at the next finer aperture-7 ccw resolution (`_downAp7`).
        mutating func downAp7() {
            self = (IJK(i: 3, j: 0, k: 1) * i + IJK(i: 1, j: 3, k: 0) * j + IJK(i: 0, j: 1, k: 3) * k).normalized()
        }

        /// Same, clockwise (`_downAp7r`).
        mutating func downAp7r() {
            self = (IJK(i: 3, j: 1, k: 0) * i + IJK(i: 0, j: 3, k: 1) * j + IJK(i: 1, j: 0, k: 3) * k).normalized()
        }

        /// Centre of the indexing parent in a clockwise aperture-7 grid (`_upAp7r`).
        mutating func upAp7r() {
            let ii = i - k, jj = j - k
            self = IJK(i: Int((Double(2 * ii + jj) / 7).rounded()),
                       j: Int((Double(3 * jj - ii) / 7).rounded()), k: 0).normalized()
        }

        func normalized() -> IJK { var c = self; c.normalize(); return c }
    }

    // MARK: Decode (h3Index.c `_h3ToFaceIjk`, faceijk.c `_adjustOverageClassII`, `_faceIjkToVec3`)

    struct FaceOrient { var face: Int; var t: IJK; var rot: Int }

    /// 7^(res/2), valid for Class II (even) res only — same domain as `unitScaleByCIIres`.
    static func unitScale(_ res: Int) -> Int { Int(pow(7.0, Double(res / 2))) }

    /// Adjusts an overhanging ijk address onto the neighbouring face. Returns true when the
    /// address was over the face edge (`NEW_FACE`).
    static func adjustOverageClassII(face: inout Int, ijk: inout IJK, res: Int, pentLeading4: Bool) -> Bool {
        let maxDim = 2 * unitScale(res)
        guard ijk.i + ijk.j + ijk.k > maxDim else { return false }
        let orient: FaceOrient
        if ijk.k > 0 {
            if ijk.j > 0 {
                orient = faceNeighbors[face][3]  // jk quadrant
            } else {
                orient = faceNeighbors[face][2]  // ki quadrant
                if pentLeading4 {
                    // Adjust for the pentagonal missing sequence.
                    let origin = IJK(i: maxDim, j: 0, k: 0)
                    var tmp = ijk - origin
                    tmp.rotate60cw()
                    ijk = tmp + origin
                }
            }
        } else {
            orient = faceNeighbors[face][1]  // ij quadrant
        }
        face = orient.face
        for _ in 0..<orient.rot { ijk.rotate60ccw() }
        ijk = (ijk + orient.t * unitScale(res)).normalized()
        return true
    }

    /// `cellToLatLng`: spherical centre of the cell, in degrees.
    static func center(_ index: UInt64) -> Coordinate {
        var h = index
        let res = resolution(h)
        let bc = baseCell(h)
        if isPentagon(bc) && leadingNonZeroDigit(h) == 5 { h = rotate60cw(h) }

        var face = baseCells[bc].face
        var ijk = baseCells[bc].ijk
        let possibleOverage = isPentagon(bc) || (res > 0 && ijk != IJK())
        if res > 0 {
            for r in 1...res {
                if isClassIII(r) { ijk.downAp7() } else { ijk.downAp7r() }
                ijk.neighbor(digit(h, r))
            }
        }

        if possibleOverage {
            let orig = ijk
            var adjRes = res
            if isClassIII(adjRes) {
                ijk.downAp7r()
                adjRes += 1
            }
            let pentLeading4 = isPentagon(bc) && leadingNonZeroDigit(h) == 4
            if adjustOverageClassII(face: &face, ijk: &ijk, res: adjRes, pentLeading4: pentLeading4) {
                if isPentagon(bc) {
                    while adjustOverageClassII(face: &face, ijk: &ijk, res: adjRes, pentLeading4: false) {}
                }
                if adjRes != res { ijk.upAp7r() }
            } else if adjRes != res {
                ijk = orig
            }
        }

        return hex2dToLatLng(ijk, face: face, res: res)
    }

    // MARK: Projection (faceijk.c `_hex2dToVec3` for a non-substrate grid, vec3d.h)

    struct Vec3 {
        var x, y, z: Double
        static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func * (a: Vec3, s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
        func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
        func cross(_ o: Vec3) -> Vec3 {
            Vec3(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x)
        }
        func normalized() -> Vec3 {
            let n = sqrt(dot(self))
            return n > 0 ? self * (1 / n) : Vec3(x: 0, y: 0, z: 0)
        }
    }

    static func posAngle(_ rads: Double) -> Double {
        var t = rads < 0 ? rads + 2 * .pi : rads
        if rads >= 2 * .pi { t -= 2 * .pi }
        return t
    }

    static func hex2dToLatLng(_ c: IJK, face: Int, res: Int) -> Coordinate {
        let i = c.i - c.k, j = c.j - c.k
        let x = Double(i) - 0.5 * Double(j)
        let y = Double(j) * 0.86602540378443864676  // M_SQRT3_2
        var r = sqrt(x * x + y * y)
        guard r >= 1e-16 else {
            let v = faceCenter[face]
            return Coordinate(latitude: asin(v.z) * 180 / .pi, longitude: atan2(v.y, v.x) * 180 / .pi)
        }
        var theta = atan2(y, x)
        for _ in 0..<res { r *= 0.37796447300922722721 }  // M_RSQRT7
        r = atan(r * 0.381966011250105)                   // RES0_U_GNOMONIC
        if isClassIII(res) { theta = posAngle(theta + 0.33347317225183211534) }  // M_AP7_ROT_RADS
        theta = posAngle(faceAxesAz[face][0] - theta)

        let p = faceCenter[face]
        let pole = Vec3(x: 0, y: 0, z: 1)
        let north = (pole + p * -pole.dot(p)).normalized()
        let east = north.cross(p)
        let dir = north * cos(theta) + east * sin(theta)
        let v = (p * cos(r) + dir * sin(r)).normalized()
        return Coordinate(latitude: asin(v.z) * 180 / .pi, longitude: atan2(v.y, v.x) * 180 / .pi)
    }

    // MARK: Tables (baseCells.c, faceijk.c — generated verbatim)

    // baseCellData: home face, home ijk+, isPentagon (cwOffsetPent unused by decode).
    private static let baseCells: [(face: Int, ijk: IJK, pentagon: Bool)] = [
        (1, IJK(i: 1, j: 0, k: 0), false),   // 0
        (2, IJK(i: 1, j: 1, k: 0), false),   // 1
        (1, IJK(i: 0, j: 0, k: 0), false),   // 2
        (2, IJK(i: 1, j: 0, k: 0), false),   // 3
        (0, IJK(i: 2, j: 0, k: 0), true),   // 4
        (1, IJK(i: 1, j: 1, k: 0), false),   // 5
        (1, IJK(i: 0, j: 0, k: 1), false),   // 6
        (2, IJK(i: 0, j: 0, k: 0), false),   // 7
        (0, IJK(i: 1, j: 0, k: 0), false),   // 8
        (2, IJK(i: 0, j: 1, k: 0), false),   // 9
        (1, IJK(i: 0, j: 1, k: 0), false),   // 10
        (1, IJK(i: 0, j: 1, k: 1), false),   // 11
        (3, IJK(i: 1, j: 0, k: 0), false),   // 12
        (3, IJK(i: 1, j: 1, k: 0), false),   // 13
        (11, IJK(i: 2, j: 0, k: 0), true),   // 14
        (4, IJK(i: 1, j: 0, k: 0), false),   // 15
        (0, IJK(i: 0, j: 0, k: 0), false),   // 16
        (6, IJK(i: 0, j: 1, k: 0), false),   // 17
        (0, IJK(i: 0, j: 0, k: 1), false),   // 18
        (2, IJK(i: 0, j: 1, k: 1), false),   // 19
        (7, IJK(i: 0, j: 0, k: 1), false),   // 20
        (2, IJK(i: 0, j: 0, k: 1), false),   // 21
        (0, IJK(i: 1, j: 1, k: 0), false),   // 22
        (6, IJK(i: 0, j: 0, k: 1), false),   // 23
        (10, IJK(i: 2, j: 0, k: 0), true),   // 24
        (6, IJK(i: 0, j: 0, k: 0), false),   // 25
        (3, IJK(i: 0, j: 0, k: 0), false),   // 26
        (11, IJK(i: 1, j: 0, k: 0), false),   // 27
        (4, IJK(i: 1, j: 1, k: 0), false),   // 28
        (3, IJK(i: 0, j: 1, k: 0), false),   // 29
        (0, IJK(i: 0, j: 1, k: 1), false),   // 30
        (4, IJK(i: 0, j: 0, k: 0), false),   // 31
        (5, IJK(i: 0, j: 1, k: 0), false),   // 32
        (0, IJK(i: 0, j: 1, k: 0), false),   // 33
        (7, IJK(i: 0, j: 1, k: 0), false),   // 34
        (11, IJK(i: 1, j: 1, k: 0), false),   // 35
        (7, IJK(i: 0, j: 0, k: 0), false),   // 36
        (10, IJK(i: 1, j: 0, k: 0), false),   // 37
        (12, IJK(i: 2, j: 0, k: 0), true),   // 38
        (6, IJK(i: 1, j: 0, k: 1), false),   // 39
        (7, IJK(i: 1, j: 0, k: 1), false),   // 40
        (4, IJK(i: 0, j: 0, k: 1), false),   // 41
        (3, IJK(i: 0, j: 0, k: 1), false),   // 42
        (3, IJK(i: 0, j: 1, k: 1), false),   // 43
        (4, IJK(i: 0, j: 1, k: 0), false),   // 44
        (6, IJK(i: 1, j: 0, k: 0), false),   // 45
        (11, IJK(i: 0, j: 0, k: 0), false),   // 46
        (8, IJK(i: 0, j: 0, k: 1), false),   // 47
        (5, IJK(i: 0, j: 0, k: 1), false),   // 48
        (14, IJK(i: 2, j: 0, k: 0), true),   // 49
        (5, IJK(i: 0, j: 0, k: 0), false),   // 50
        (12, IJK(i: 1, j: 0, k: 0), false),   // 51
        (10, IJK(i: 1, j: 1, k: 0), false),   // 52
        (4, IJK(i: 0, j: 1, k: 1), false),   // 53
        (12, IJK(i: 1, j: 1, k: 0), false),   // 54
        (7, IJK(i: 1, j: 0, k: 0), false),   // 55
        (11, IJK(i: 0, j: 1, k: 0), false),   // 56
        (10, IJK(i: 0, j: 0, k: 0), false),   // 57
        (13, IJK(i: 2, j: 0, k: 0), true),   // 58
        (10, IJK(i: 0, j: 0, k: 1), false),   // 59
        (11, IJK(i: 0, j: 0, k: 1), false),   // 60
        (9, IJK(i: 0, j: 1, k: 0), false),   // 61
        (8, IJK(i: 0, j: 1, k: 0), false),   // 62
        (6, IJK(i: 2, j: 0, k: 0), true),   // 63
        (8, IJK(i: 0, j: 0, k: 0), false),   // 64
        (9, IJK(i: 0, j: 0, k: 1), false),   // 65
        (14, IJK(i: 1, j: 0, k: 0), false),   // 66
        (5, IJK(i: 1, j: 0, k: 1), false),   // 67
        (16, IJK(i: 0, j: 1, k: 1), false),   // 68
        (8, IJK(i: 1, j: 0, k: 1), false),   // 69
        (5, IJK(i: 1, j: 0, k: 0), false),   // 70
        (12, IJK(i: 0, j: 0, k: 0), false),   // 71
        (7, IJK(i: 2, j: 0, k: 0), true),   // 72
        (12, IJK(i: 0, j: 1, k: 0), false),   // 73
        (10, IJK(i: 0, j: 1, k: 0), false),   // 74
        (9, IJK(i: 0, j: 0, k: 0), false),   // 75
        (13, IJK(i: 1, j: 0, k: 0), false),   // 76
        (16, IJK(i: 0, j: 0, k: 1), false),   // 77
        (15, IJK(i: 0, j: 1, k: 1), false),   // 78
        (15, IJK(i: 0, j: 1, k: 0), false),   // 79
        (16, IJK(i: 0, j: 1, k: 0), false),   // 80
        (14, IJK(i: 1, j: 1, k: 0), false),   // 81
        (13, IJK(i: 1, j: 1, k: 0), false),   // 82
        (5, IJK(i: 2, j: 0, k: 0), true),   // 83
        (8, IJK(i: 1, j: 0, k: 0), false),   // 84
        (14, IJK(i: 0, j: 0, k: 0), false),   // 85
        (9, IJK(i: 1, j: 0, k: 1), false),   // 86
        (14, IJK(i: 0, j: 0, k: 1), false),   // 87
        (17, IJK(i: 0, j: 0, k: 1), false),   // 88
        (12, IJK(i: 0, j: 0, k: 1), false),   // 89
        (16, IJK(i: 0, j: 0, k: 0), false),   // 90
        (17, IJK(i: 0, j: 1, k: 1), false),   // 91
        (15, IJK(i: 0, j: 0, k: 1), false),   // 92
        (16, IJK(i: 1, j: 0, k: 1), false),   // 93
        (9, IJK(i: 1, j: 0, k: 0), false),   // 94
        (15, IJK(i: 0, j: 0, k: 0), false),   // 95
        (13, IJK(i: 0, j: 0, k: 0), false),   // 96
        (8, IJK(i: 2, j: 0, k: 0), true),   // 97
        (13, IJK(i: 0, j: 1, k: 0), false),   // 98
        (17, IJK(i: 1, j: 0, k: 1), false),   // 99
        (19, IJK(i: 0, j: 1, k: 0), false),   // 100
        (14, IJK(i: 0, j: 1, k: 0), false),   // 101
        (19, IJK(i: 0, j: 1, k: 1), false),   // 102
        (17, IJK(i: 0, j: 1, k: 0), false),   // 103
        (13, IJK(i: 0, j: 0, k: 1), false),   // 104
        (17, IJK(i: 0, j: 0, k: 0), false),   // 105
        (16, IJK(i: 1, j: 0, k: 0), false),   // 106
        (9, IJK(i: 2, j: 0, k: 0), true),   // 107
        (15, IJK(i: 1, j: 0, k: 1), false),   // 108
        (15, IJK(i: 1, j: 0, k: 0), false),   // 109
        (18, IJK(i: 0, j: 1, k: 1), false),   // 110
        (18, IJK(i: 0, j: 0, k: 1), false),   // 111
        (19, IJK(i: 0, j: 0, k: 1), false),   // 112
        (17, IJK(i: 1, j: 0, k: 0), false),   // 113
        (19, IJK(i: 0, j: 0, k: 0), false),   // 114
        (18, IJK(i: 0, j: 1, k: 0), false),   // 115
        (18, IJK(i: 1, j: 0, k: 1), false),   // 116
        (19, IJK(i: 2, j: 0, k: 0), true),   // 117
        (19, IJK(i: 1, j: 0, k: 0), false),   // 118
        (18, IJK(i: 0, j: 0, k: 0), false),   // 119
        (19, IJK(i: 1, j: 0, k: 1), false),   // 120
        (18, IJK(i: 1, j: 0, k: 0), false),   // 121
    ]

    // faceCenterPoint: icosahedron face centres on the unit sphere.
    private static let faceCenter: [Vec3] = [
        Vec3(x: 0.2199307791404606, y: 0.6583691780274996, z: 0.7198475378926182),   // 0
        Vec3(x: -0.2139234834501421, y: 0.1478171829550703, z: 0.9656017935214205),   // 1
        Vec3(x: 0.1092625278784797, y: -0.481195157287321, z: 0.8697775121287253),   // 2
        Vec3(x: 0.7428567301586791, y: -0.3593941678278028, z: 0.5648005936517033),   // 3
        Vec3(x: 0.8112534709140969, y: 0.3448953237639384, z: 0.472138773641393),   // 4
        Vec3(x: -0.1055498149613921, y: 0.9794457296411413, z: 0.1718874610009365),   // 5
        Vec3(x: -0.8075407579970092, y: 0.1533552485898818, z: 0.5695261994882688),   // 6
        Vec3(x: -0.2846148069787907, y: -0.8644080972654206, z: 0.4144792552473539),   // 7
        Vec3(x: 0.7405621473854482, y: -0.6673299564565524, z: -0.0789837646326737),   // 8
        Vec3(x: 0.8512303986474293, y: 0.4722343788582681, z: -0.2289137388687808),   // 9
        Vec3(x: -0.7405621473854481, y: 0.6673299564565524, z: 0.0789837646326737),   // 10
        Vec3(x: -0.8512303986474292, y: -0.4722343788582682, z: 0.2289137388687808),   // 11
        Vec3(x: 0.1055498149613919, y: -0.9794457296411413, z: -0.1718874610009365),   // 12
        Vec3(x: 0.8075407579970092, y: -0.1533552485898819, z: -0.5695261994882688),   // 13
        Vec3(x: 0.2846148069787908, y: 0.8644080972654204, z: -0.4144792552473539),   // 14
        Vec3(x: -0.7428567301586791, y: 0.3593941678278027, z: -0.5648005936517033),   // 15
        Vec3(x: -0.8112534709140971, y: -0.3448953237639382, z: -0.472138773641393),   // 16
        Vec3(x: -0.2199307791404607, y: -0.6583691780274996, z: -0.7198475378926182),   // 17
        Vec3(x: 0.213923483450142, y: -0.1478171829550704, z: -0.9656017935214205),   // 18
        Vec3(x: -0.1092625278784796, y: 0.481195157287321, z: -0.8697775121287253),   // 19
    ]

    // faceAxesAzRadsCII: azimuth in radians from face centre to vertex 0/1/2.
    private static let faceAxesAz: [[Double]] = [
        [5.6199582685239395, 3.5255631661307447, 1.4311680637375488],   // 0
        [5.7603390817141875, 3.665943979320992, 1.571548876927796],   // 1
        [0.78021365439343, 4.969003859179821, 2.8746087567866256],   // 2
        [0.4304693639799999, 4.619259568766391, 2.5248644663731956],   // 3
        [6.130269123335111, 4.0358740209419155, 1.9414789185487202],   // 4
        [2.692877706530643, 0.5984826041374471, 4.787272808923838],   // 5
        [2.982963003477244, 0.8885679010840484, 5.07735810587044],   // 6
        [3.532912002790141, 1.4385169003969456, 5.627307105183337],   // 7
        [3.494305004259568, 1.3999099018663728, 5.588700106652764],   // 8
        [3.0032141694995382, 0.908819067106343, 5.0976092718927335],   // 9
        [5.930472956509812, 3.836077854116616, 1.7416827517234204],   // 10
        [0.13837848409025486, 4.327168688876646, 2.23277358648345],   // 11
        [0.4487149470591504, 4.6375051518455415, 2.543110049452346],   // 12
        [0.15862965011254937, 4.3474198548989405, 2.2530247525057447],   // 13
        [5.891865957979238, 3.797470855586043, 1.7030757531928475],   // 14
        [2.711123289609793, 0.6167281872165977, 4.8055183920029885],   // 15
        [3.294508837434268, 1.2001137350410729, 5.388903939827464],   // 16
        [3.80481969224544, 1.7104245898522445, 5.8992147946386355],   // 17
        [3.6644388790551923, 1.570043776661997, 5.758833981448388],   // 18
        [2.361378999196363, 0.2669838968031676, 4.455774101589559],   // 19
    ]

    // faceNeighbors: {face, translate, ccwRot60} per {centre, ij, ki, jk} quadrant.
    private static let faceNeighbors: [[FaceOrient]] = [
        [FaceOrient(face: 0, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 4, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 1, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 5, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 0
        [FaceOrient(face: 1, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 0, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 2, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 6, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 1
        [FaceOrient(face: 2, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 1, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 3, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 7, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 2
        [FaceOrient(face: 3, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 2, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 4, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 8, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 3
        [FaceOrient(face: 4, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 3, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 0, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 9, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 4
        [FaceOrient(face: 5, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 10, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 14, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 0, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 5
        [FaceOrient(face: 6, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 11, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 10, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 1, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 6
        [FaceOrient(face: 7, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 12, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 11, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 2, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 7
        [FaceOrient(face: 8, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 13, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 12, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 3, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 8
        [FaceOrient(face: 9, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 14, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 13, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 4, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 9
        [FaceOrient(face: 10, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 5, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 6, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 15, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 10
        [FaceOrient(face: 11, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 6, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 7, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 16, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 11
        [FaceOrient(face: 12, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 7, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 8, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 17, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 12
        [FaceOrient(face: 13, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 8, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 9, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 18, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 13
        [FaceOrient(face: 14, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 9, t: IJK(i: 2, j: 2, k: 0), rot: 3), FaceOrient(face: 5, t: IJK(i: 2, j: 0, k: 2), rot: 3), FaceOrient(face: 19, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 14
        [FaceOrient(face: 15, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 16, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 19, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 10, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 15
        [FaceOrient(face: 16, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 17, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 15, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 11, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 16
        [FaceOrient(face: 17, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 18, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 16, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 12, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 17
        [FaceOrient(face: 18, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 19, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 17, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 13, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 18
        [FaceOrient(face: 19, t: IJK(i: 0, j: 0, k: 0), rot: 0), FaceOrient(face: 15, t: IJK(i: 2, j: 0, k: 2), rot: 1), FaceOrient(face: 18, t: IJK(i: 2, j: 2, k: 0), rot: 5), FaceOrient(face: 14, t: IJK(i: 0, j: 2, k: 2), rot: 3)],   // 19
    ]
}
