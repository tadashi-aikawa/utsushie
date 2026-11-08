import Foundation

/// スクロール撮影の照合に使う1コマの明るさ。横は列を平均して縮め、縦はつなぐ画像と同じ画素の行で持つ。
/// 理由: ずれは縦の画素単位で決めるが、横の細かさは照合にほとんど効かないため。
public struct ScrollLuma: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let values: [UInt8]
    public init(width: Int, height: Int, values: [UInt8]) {
        precondition(values.count == width * height)
        self.width = width; self.height = height; self.values = values
    }
}

/// 1コマを足した結果。どの行を本体・末尾の固定部分へ写すかだけを返し、画素は呼び出し側が持つ。
public struct ScrollStep: Equatable, Sendable {
    /// 最初のコマとして残す行。上限で切ってある。最初のコマだけで返す。
    public var first: Range<Int>?
    /// 最初のコマから本体へ入れる行。初めて動いたときに1回だけ返す。
    public var seed: Range<Int>?
    /// 最初のコマから末尾の固定部分として持つ行。初めて動いたのが上向きのときだけ返す。
    public var seedFooter: Range<Int>?
    /// 今のコマから本体の末尾へ足す行。
    public var append: Range<Int>?
    /// 今のコマから末尾の固定部分として持ち直す行。いちばん下まで進んだコマのときだけ返す。
    public var footer: Range<Int>?
    /// 前のコマとの重なりが見つからなかった。戻して重なりが見つかれば続ける。
    public var lost = false
    /// 上限に届いた。足した行は上限までで切ってある。
    public var reachedLimit = false
    public init(first: Range<Int>? = nil, seed: Range<Int>? = nil, seedFooter: Range<Int>? = nil, append: Range<Int>? = nil,
                footer: Range<Int>? = nil, lost: Bool = false, reachedLimit: Bool = false) {
        self.first = first; self.seed = seed; self.seedFooter = seedFooter; self.append = append; self.footer = footer
        self.lost = lost; self.reachedLimit = reachedLimit
    }
}

/// 利用者がスクロールした分を、コマ同士の縦のずれから1枚へつなぐ。
///
/// - 画像の並び: 最初のコマの頭 + 新しく見えた行 + いちばん下まで進んだコマの末尾の固定部分
/// - 固定部分: 初めて動いたときに、同じ位置で変わらない上下の行を固定のヘッダー・フッターとし、以後は変えない
///     - 理由: 余白の行を固定と取り違えても、中身はその後のコマで真ん中を通って足されるので崩れない
/// - 上へ戻した分は足さない。重なりが見つからなければ、最後につないだコマを基準に残して待つ
public struct ScrollStitcher: Sendable {
    /// WebPの1辺の上限。
    public static let webPLimit = 16383
    public let maxHeight: Int
    public private(set) var header: Int?
    public private(set) var footerHeight: Int?
    public private(set) var bodyHeight = 0
    public private(set) var lost = false
    public private(set) var reachedLimit = false
    /// 直前の照合に使った列。固定のサイドバーや余白のように動かない列は外す。
    /// コマごとに決め直す。理由: ページの途中で本文の横の位置が変わると、最初は余白だった列に中身が出るため。
    public private(set) var columns: [Int]?
    private var reference: ScrollLuma?
    private var referenceTop = 0
    private var lastShift = 0
    private var frameHeight = 0

    public init(maxHeight: Int = ScrollStitcher.webPLimit) { self.maxHeight = maxHeight }

    /// つないだ画像の高さ。まだ動いていなければ最初のコマの高さ。
    public var outputHeight: Int {
        guard let footerHeight else { return frameHeight }
        return bodyHeight + footerHeight
    }
    /// 一度も動かなかった。最初のコマをそのまま使う。
    public var isStill: Bool { footerHeight == nil }

    public mutating func add(_ frame: ScrollLuma) -> ScrollStep {
        guard !reachedLimit else { return ScrollStep(reachedLimit: true) }
        guard let reference else {
            self.reference = frame; frameHeight = min(frame.height, maxHeight)
            if frame.height >= maxHeight { reachedLimit = true }
            return ScrollStep(first: 0..<frameHeight, reachedLimit: reachedLimit)
        }
        guard frame.width == reference.width, frame.height == reference.height else { return ScrollStep() }
        let height = frame.height
        var top = header ?? 0, bottom = footerHeight ?? 0
        if header == nil {
            // 小さいウィンドウでは固定のツールバーが大半を占めることがあるので、固定部分の高さは制限しない。
            (top, bottom) = ScrollMatcher.fixedRows(reference, frame, limit: height)
            // 上下の固定部分が全体を覆うなら、何も動いていない。
            if height - top - bottom < ScrollMatcher.minimumRegion { return ScrollStep() }
        }
        // 中身の動いた列が無ければ、同じコマがもう一度届いただけ。動きは0に決める。
        guard let matched = ScrollMatcher.movingColumns(reference, frame, rows: top..<(height - bottom)) else {
            return ScrollStep(lost: lost)
        }
        columns = matched
        switch ScrollMatcher.shift(reference, frame, top: top, bottom: bottom, columns: matched, hint: lastShift) {
        case .lost:
            lost = true
            return ScrollStep(lost: true)
        case .unknown:
            // 平らで手がかりが無い。基準を残して次のコマを待つ。
            return ScrollStep(lost: lost)
        case let .shift(shift):
            lost = false
            guard shift != 0 else { self.reference = frame; return ScrollStep() }
            if header == nil {
                bottom += ScrollMatcher.edgeRows(reference, frame, top: top, bottom: bottom, shift: shift)
            }
            return accept(frame, shift: shift, top: top, bottom: bottom)
        }
    }

    private mutating func accept(_ frame: ScrollLuma, shift: Int, top: Int, bottom: Int) -> ScrollStep {
        let height = frame.height
        var step = ScrollStep()
        let currentTop = referenceTop + shift
        if header == nil {
            header = top; footerHeight = bottom
            bodyHeight = min(height - bottom, maxHeight - bottom)
            step.seed = 0..<bodyHeight
            if bottom > 0, currentTop + height - bottom < bodyHeight { step.seedFooter = (height - bottom)..<height }
        }
        let fixedTop = header ?? 0, fixedBottom = footerHeight ?? 0
        let end = height - fixedBottom
        let start = max(fixedTop, bodyHeight - currentTop)
        if start < end {
            var count = end - start
            let room = maxHeight - fixedBottom - bodyHeight
            if count >= room { count = max(0, room); reachedLimit = true }
            if count > 0 { step.append = start..<(start + count); bodyHeight += count }
        }
        if fixedBottom > 0, currentTop + end >= bodyHeight { step.footer = end..<height }
        step.reachedLimit = reachedLimit
        reference = frame; referenceTop = currentTop; lastShift = shift
        return step
    }
}

/// `ScrollStep`の行を画素のまま写して、つないだ画像の行を組む。1行は`rowBytes`バイトの詰めた並び。
public struct ScrollCanvas: Sendable {
    public let rowBytes: Int
    private var first: [UInt8] = []
    private var body: [UInt8] = []
    private var footer: [UInt8] = []
    public init(rowBytes: Int) { self.rowBytes = rowBytes }

    /// `frame`は1行`stride`バイトのコマ。
    public mutating func add(_ frame: UnsafeRawBufferPointer, stride: Int, step: ScrollStep) {
        func rows(_ range: Range<Int>, from source: UnsafeRawBufferPointer, stride: Int) -> [UInt8] {
            var result = [UInt8](); result.reserveCapacity(range.count * rowBytes)
            for row in range {
                let start = row * stride
                result.append(contentsOf: UnsafeRawBufferPointer(rebasing: source[start..<(start + rowBytes)]))
            }
            return result
        }
        if let range = step.first { first = rows(range, from: frame, stride: stride) }
        if let seed = step.seed { body = Array(first[(seed.lowerBound * rowBytes)..<(seed.upperBound * rowBytes)]) }
        if let seedFooter = step.seedFooter {
            footer = Array(first[(seedFooter.lowerBound * rowBytes)..<(seedFooter.upperBound * rowBytes)])
        }
        if let append = step.append { body += rows(append, from: frame, stride: stride) }
        if let range = step.footer { footer = rows(range, from: frame, stride: stride) }
    }
    /// 一度も動かなければ最初のコマ。
    public func output(still: Bool) -> [UInt8] { still ? first : body + footer }
}

public enum ScrollMatch: Equatable, Sendable {
    /// 中身が上へ動いた行数。負なら上へ戻した。
    case shift(Int)
    /// 平らで、どれだけ動いたか決められない。
    case unknown
    /// 重なりが見つからない。
    case lost
}

public enum ScrollMatcher {
    /// 1値あたりの平均の差がこれ以下なら同じ行とみなす。
    static let sameRow = 1
    /// 末尾の固定部分の上で、中身と一緒に動かない縁の行を探す行数。
    /// 理由: 縮小で混ざる行やフッターの影は数行に収まり、広く探すほど照合する範囲を削るため。
    static let edgeWindow = 24
    /// 重なりの差を、両方のコマの中身の量で割った割合。これを超えたら重なりは見つからないとする。
    /// 理由: 全部の値の平均では、白地の多い画面で違う文字同士の差が白に薄まり、重なりが無くても一致に見えるため。
    ///     割合なら、一致は0、無関係な中身同士はおよそ1になる。1xへの縮小で残る半画素のずれの分だけゆとりを持たせる。
    static let matchLimit = 0.4
    /// 1値あたりの中身の量がこれ未満なら、平らで動きを決められない。
    static let flatEnergy = 0.2
    /// 候補を絞るときに、列を分ける区間の数。
    static let sections = 16
    /// 粗い比較から全部の列で確かめる候補の数の上限。
    static let candidateLimit = 32
    /// 動く中身がこれより低ければ照合しない。
    public static let minimumRegion = 12

    public static func minimumOverlap(region: Int) -> Int { max(minimumRegion, region / 8) }

    /// 同じ位置で中身が変わった列。固定のサイドバーや余白の列は外す。1列も変わっていなければnil。
    /// 理由: 動かない列は正しいずれでも差を生み、白い余白は違う中身同士の差を薄めるため。
    public static func movingColumns(_ a: ScrollLuma, _ b: ScrollLuma, rows: Range<Int>) -> [Int]? {
        let width = a.width
        var moving: [Int] = []
        a.values.withUnsafeBufferPointer { pa in
            b.values.withUnsafeBufferPointer { pb in
                for column in 0..<width {
                    var total = 0
                    for row in rows { total += abs(Int(pa[row * width + column]) - Int(pb[row * width + column])) }
                    if total > rows.count * sameRow { moving.append(column) }
                }
            }
        }
        return moving.isEmpty ? nil : moving
    }

    /// 同じ位置で変わらない上下の行数。どちらも`limit`までに留める。
    public static func fixedRows(_ a: ScrollLuma, _ b: ScrollLuma, limit: Int) -> (top: Int, bottom: Int) {
        let height = a.height, width = a.width
        func same(_ row: Int) -> Bool { rowDifference(a, row, b, row) <= sameRow * width }
        var top = 0
        while top < min(limit, height), same(top) { top += 1 }
        var bottom = 0
        while bottom < min(limit, height - top), same(height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    /// 末尾の固定部分の上で、中身と一緒に動かない行の数。固定部分に足すと、継ぎ目ごとに足す行へ入らない。
    ///
    /// - 対象: フッターの縁や影、1xへの縮小でフッターと下を流れる中身が混ざった行。コマごとに変わるので`fixedRows`では固定にならない
    /// - 判定: 中身の側のコマで、その行の中身が動いた先の行と比べる。`edgeWindow`行のうち、食い違う最も上の行までを数える
    ///     - 中身の側: 下へ進んだら基準のコマ、上へ戻したら今のコマ。動いた先の行は混ざる前の中身なので、混ざった行だけが食い違う
    ///     - 間: 縮小で混ざった行は、間に混ざらない行を挟んで離れて出ることがある。一致する行で止めない
    ///     - 基準: 動いた先が範囲に収まる行の食い違いの、小さいほうから1/4の値を超えた分で測る
    ///         - 理由: 縮小で全体の明るさが僅かにずれると、どの行も同じだけ食い違い、縁と取り違えるため
    ///         - 1/4: 初回に大きく動くと重なりが少なく、縁の行が半分を超えることがある。3/4未満なら基準は中身の行で決まる
    ///         - 縮小のにじみ: 文字の行ほど食い違うので、基準を超えた中身の行も縁に入りうる。取りすぎても照合する範囲が狭まるだけ
    /// - 上限: `edgeWindow`行と、動く範囲の1/4の小さいほう
    ///     - 理由: 中身の行を固定部分に取り違えても、中身はその後のコマで上側を通って足されるので崩れない。ただ照合する範囲は狭まる
    public static func edgeRows(_ reference: ScrollLuma, _ current: ScrollLuma, top: Int, bottom: Int, shift: Int) -> Int {
        let height = reference.height
        let (content, moved) = shift > 0 ? (reference, current) : (current, reference)
        let distance = abs(shift)
        let region = height - top - bottom
        let limit = min(edgeWindow, region / 4, region - minimumRegion)
        guard limit > 0 else { return 0 }
        func difference(_ row: Int) -> Int { rowDifference(content, row, moved, row - distance) }
        // 動いた先が範囲に収まる行。探す行も含める。
        // 理由: 大きく動くと探す行より上に行が残らず、基準を測れないため。
        let lower = top + distance, upper = height - bottom
        guard lower < upper else { return 0 }
        let base = (lower..<upper).map(difference).sorted()[(upper - lower) / 4]
        var edge = 0
        for count in 0..<limit {
            let row = height - bottom - 1 - count
            guard row - distance >= top else { break }
            if difference(row) > base + sameRow * content.width { edge = count + 1 }
        }
        return edge
    }

    /// 基準のコマから今のコマへ、中身が何行上へ動いたか。`columns`の列だけで比べる。
    ///
    /// - 候補: 1つしか無い行の一致による投票と、列を区間ごとに平均した粗い比較の上位
    ///     - 理由: 等間隔の行が並ぶ画面や大きい画面では、粗い比較だけだと似た候補が多く並び、正しいずれが上限から落ちるため
    /// - 決め方: 候補を全部の列で確かめ、差の割合が最小のもの。近い割合の候補は前回の動きに近いほう
    public static func shift(_ reference: ScrollLuma, _ current: ScrollLuma, top: Int, bottom: Int,
                             columns: [Int]? = nil, hint: Int) -> ScrollMatch {
        let height = reference.height
        let columns = columns ?? Array(0..<reference.width)
        let region = height - top - bottom
        let maximum = region - minimumOverlap(region: region)
        guard maximum >= 0, !columns.isEmpty else { return .lost }
        let a = Features(reference, columns: columns), b = Features(current, columns: columns)
        let rows = top..<(height - bottom)
        var candidates: [Int] = []
        for hashes in [\Features.pairs, \Features.runs] {
            for shift in votedShifts(a[keyPath: hashes], b[keyPath: hashes], rows: rows, maximum: maximum) where !candidates.contains(shift) {
                candidates.append(shift)
            }
        }
        for shift in coarseShifts(a, b, top: top, bottom: bottom, maximum: maximum, hint: hint) where !candidates.contains(shift) {
            candidates.append(shift)
        }
        var result = choose(refine(a, b, candidates, top: top, bottom: bottom), hint: hint)
        if result == .lost {
            // 似た行の種類が少ないと、投票も粗い比較も正しいずれを外すことがある。見失う前に、全部のずれを行を間引いて確かめ直す。
            let sparse = sampledShifts(a, b, top: top, bottom: bottom, maximum: maximum).filter { !candidates.contains($0) }
            // 確かめ直しで一致が見つかったときだけ取り消す。平らで決められないだけなら、見失ったままにする。
            let retry = choose(refine(a, b, sparse, top: top, bottom: bottom), hint: hint)
            if case .shift = retry { result = retry }
        }
        return result
    }

    /// 候補ごとの差の割合。平らな重なりは、どのずれでも一致して見えるので外す。
    static func refine(_ a: Features, _ b: Features, _ candidates: [Int], top: Int, bottom: Int) -> [(shift: Int, ratio: Double)] {
        let height = a.height
        var refined: [(shift: Int, ratio: Double)] = []
        for shift in candidates {
            let first = top + max(0, shift), last = height - bottom + min(0, shift)
            var difference = 0, energy = 0
            for row in first..<last {
                difference += Features.difference(a, row, b, row - shift)
                energy += a.energies[row] + b.energies[row - shift]
            }
            guard Double(energy) >= flatEnergy * Double((last - first) * a.width * 2) else { continue }
            refined.append((shift, 2 * Double(difference) / Double(energy)))
        }
        return refined
    }
    static func choose(_ refined: [(shift: Int, ratio: Double)], hint: Int) -> ScrollMatch {
        guard let best = refined.map(\.ratio).min() else { return .unknown }
        guard best <= matchLimit else { return .lost }
        // 前回の動きに近いほうを選ぶのは、差がほぼ同じ候補の間だけ。ほぼ一致する候補があれば、少しでも差の残る候補は選ばない。
        let close = refined.filter { $0.ratio <= min(matchLimit, best * 1.5 + 0.01) }
        guard let chosen = close.min(by: { abs($0.shift - hint) < abs($1.shift - hint) })?.shift else { return .lost }
        return .shift(chosen)
    }

    /// 全部のずれを、8行おきの行と全部の列で比べた差の小さい8件。
    static func sampledShifts(_ a: Features, _ b: Features, top: Int, bottom: Int, maximum: Int) -> [Int] {
        let height = a.height
        var costs: [(shift: Int, cost: Double)] = []
        for shift in -maximum...maximum {
            let first = top + max(0, shift), last = height - bottom + min(0, shift)
            var total = 0, samples = 0
            var row = first
            while row < last { total += Features.difference(a, row, b, row - shift); samples += 1; row += 8 }
            if samples > 0 { costs.append((shift, Double(total) / Double(samples))) }
        }
        return costs.sorted { $0.cost < $1.cost }.prefix(8).map(\.shift)
    }

    /// 基準のコマで1回しか出ない要約が、今のコマのどこへ動いたかを数える。2票以上のずれを多い順に返す。
    static func votedShifts(_ a: [UInt64], _ b: [UInt64], rows: Range<Int>, maximum: Int) -> [Int] {
        var counts: [UInt64: Int] = [:], positions: [UInt64: Int] = [:]
        for row in rows where a[row] != 0 { counts[a[row], default: 0] += 1; positions[a[row]] = row }
        var votes: [Int: Int] = [:]
        for row in rows {
            let hash = b[row]
            guard hash != 0, counts[hash] == 1, let origin = positions[hash] else { continue }
            let shift = origin - row
            if abs(shift) <= maximum { votes[shift, default: 0] += 1 }
        }
        return votes.filter { $0.value >= 2 }.sorted { $0.value > $1.value || $0.value == $1.value && $0.key < $1.key }
            .prefix(8).map(\.key)
    }

    /// 区間の平均で比べた差の小さいずれ。差が近いものは最大`candidateLimit`件まで含める。
    static func coarseShifts(_ a: Features, _ b: Features, top: Int, bottom: Int, maximum: Int, hint: Int) -> [Int] {
        let height = a.height
        var coarse: [(shift: Int, cost: Double)] = []
        coarse.reserveCapacity(maximum * 2 + 1)
        a.signatures.withUnsafeBufferPointer { sa in
            b.signatures.withUnsafeBufferPointer { sb in
                for shift in -maximum...maximum {
                    let first = top + max(0, shift), last = height - bottom + min(0, shift)
                    var total = 0, samples = 0
                    var row = first
                    while row < last {
                        let x = row * sections, y = (row - shift) * sections
                        for section in 0..<sections { total += abs(sa[x + section] - sb[y + section]) }
                        samples += sections
                        row += 2
                    }
                    if samples > 0 { coarse.append((shift, Double(total) / Double(samples))) }
                }
            }
        }
        coarse.sort { $0.cost < $1.cost || $0.cost == $1.cost && abs($0.shift - hint) < abs($1.shift - hint) }
        let near = (coarse.first?.cost ?? 0) + 2
        return coarse.enumerated().filter { $0.offset < 8 || $0.element.cost <= near }.prefix(candidateLimit).map(\.element.shift)
    }

    /// 照合に使う列だけを詰めた1コマと、行ごとの特徴。
    struct Features {
        let width: Int
        let height: Int
        let values: [UInt8]
        /// 行ごとに、列を`sections`個の区間に分けた平均。
        let signatures: [Int]
        /// 行ごとの中身の量。行の中の明るさの差に、上の行との平均の差を足す。
        /// 理由: 横幅いっぱいが同じ色の行ばかりの画面でも、色の変わる行で縦の位置を見分けるため。
        let energies: [Int]
        /// 行と上の行の明るさを粗く丸めた値の要約。どちらも平らなら0。
        /// 理由: 文字の行は同じ並びの画素が数行続くことがあり、1行だけでは1回しか出ない行が見つからないため。上の行と組にすると、文字の行の始まりと終わりが1回だけになる。
        let pairs: [UInt64]
        /// 上の`runLength`行までの並びの要約。少ない種類の行が並ぶ画面でも、並び方で1回だけになる。
        let runs: [UInt64]
        static let runLength = 32

        init(_ frame: ScrollLuma, columns: [Int]) {
            let width = columns.count, height = frame.height
            var values = [UInt8](repeating: 0, count: width * height)
            frame.values.withUnsafeBufferPointer { source in
                for row in 0..<height {
                    for (index, column) in columns.enumerated() { values[row * width + index] = source[row * frame.width + column] }
                }
            }
            var signatures = [Int](repeating: 0, count: height * sections)
            var energies = [Int](repeating: 0, count: height)
            var rowHashes = [UInt64](repeating: 0, count: height)
            var textured = [Bool](repeating: false, count: height)
            values.withUnsafeBufferPointer { values in
                var previousMean = 0
                for row in 0..<height {
                    let base = row * width
                    var total = 0
                    for column in 0..<width { total += Int(values[base + column]) }
                    let mean = total / width
                    var horizontal = 0
                    var hash: UInt64 = 0xcbf29ce484222325
                    for column in 0..<width {
                        let value = Int(values[base + column])
                        horizontal += abs(value - mean)
                        hash = (hash ^ UInt64(value >> 3)) &* 0x100000001b3
                    }
                    energies[row] = horizontal + (row > 0 ? abs(mean - previousMean) * width : 0)
                    rowHashes[row] = hash; textured[row] = horizontal >= width
                    previousMean = mean
                    for section in 0..<sections {
                        let start = min(section * width / sections, width - 1)
                        let end = min(width, max(start + 1, (section + 1) * width / sections))
                        var sum = 0
                        for column in start..<end { sum += Int(values[base + column]) }
                        signatures[row * sections + section] = sum / (end - start)
                    }
                }
            }
            func combine(_ a: UInt64, _ b: UInt64) -> UInt64 { (a &* 0x9e3779b97f4a7c15) ^ b }
            var pairs = [UInt64](repeating: 0, count: height)
            for row in 1..<max(1, height) where textured[row] || textured[row - 1] {
                pairs[row] = max(1, combine(rowHashes[row - 1], rowHashes[row]))
            }
            var runs = [UInt64](repeating: 0, count: height)
            let length = Self.runLength
            if height >= length {
                for row in (length - 1)..<height where ((row - length + 1)...row).contains(where: { textured[$0] }) {
                    var hash: UInt64 = 0
                    for index in (row - length + 1)...row { hash = combine(hash, rowHashes[index]) }
                    runs[row] = max(1, hash)
                }
            }
            self.width = width; self.height = height; self.values = values
            self.signatures = signatures; self.energies = energies; self.pairs = pairs; self.runs = runs
        }

        static func difference(_ a: Features, _ rowA: Int, _ b: Features, _ rowB: Int) -> Int {
            let width = a.width
            return a.values.withUnsafeBufferPointer { pa in
                b.values.withUnsafeBufferPointer { pb in
                    var total = 0
                    let x = rowA * width, y = rowB * width
                    for column in 0..<width { total += abs(Int(pa[x + column]) - Int(pb[y + column])) }
                    return total
                }
            }
        }
    }

    static func rowDifference(_ a: ScrollLuma, _ rowA: Int, _ b: ScrollLuma, _ rowB: Int) -> Int {
        let width = a.width
        return a.values.withUnsafeBufferPointer { pa in
            b.values.withUnsafeBufferPointer { pb in
                var total = 0
                let x = rowA * width, y = rowB * width
                for column in 0..<width { total += abs(Int(pa[x + column]) - Int(pb[y + column])) }
                return total
            }
        }
    }
}

public enum ScrollPresentation {
    /// 撮っている途中のバッジ。つないだ高さと上限のpx。
    public static func badge(height: Int, limit: Int = ScrollStitcher.webPLimit) -> String {
        "↓ \(grouped(height)) / \(grouped(limit))px"
    }
    public static let lost = "速すぎます 少し戻してください"
    /// メニューバーの札。押すと止める。
    public static func status(height: Int) -> String { "■ ↓ \(grouped(height))px" }
    /// 上限で止めたときにカードへ出す。
    public static let limitNotice = "上限で止めた"
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }
}
