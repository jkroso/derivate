/// What a site's result is: a password from templates, a password the user
/// stored, or a key. Its value is Spectre's, as export files keep it.
public struct ResultType: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    private static let classTemplate: UInt32 = 1 << 4
    private static let classStateful: UInt32 = 1 << 5
    private static let classDerive: UInt32 = 1 << 6
    private static let featureExportContent: UInt32 = 1 << 10
    private static let featureDevicePrivate: UInt32 = 1 << 11
    private static let featureAlternate: UInt32 = 1 << 12

    /// 20 characters, of every class.
    public static let maximum = ResultType(rawValue: 0x0 | classTemplate)
    /// 14 letters, digits and a symbol.
    public static let long = ResultType(rawValue: 0x1 | classTemplate)
    /// 8 letters, digits and a symbol.
    public static let medium = ResultType(rawValue: 0x2 | classTemplate)
    /// 8 letters and digits.
    public static let basic = ResultType(rawValue: 0x4 | classTemplate)
    /// 4 letters and a digit.
    public static let short = ResultType(rawValue: 0x3 | classTemplate)
    /// 4 digits.
    public static let pin = ResultType(rawValue: 0x5 | classTemplate)
    /// 9 lower-case letters, as login names.
    public static let name = ResultType(rawValue: 0xE | classTemplate)
    /// Words of lower-case letters, as security answers.
    public static let phrase = ResultType(rawValue: 0xF | classTemplate)
    /// A password the user stored.
    public static let personal = ResultType(rawValue: 0x0 | classStateful | featureExportContent)
    /// A password stored on the device, which exports leave out.
    public static let device = ResultType(rawValue: 0x1 | classStateful | featureDevicePrivate)
    /// A binary key.
    public static let deriveKey = ResultType(rawValue: 0x0 | classDerive | featureAlternate)

    /// The types a site's password may take, in the order Spectre lists them.
    public static let passwordTypes: [ResultType] = [.maximum, .long, .medium, .basic, .short, .pin, .name, .phrase, .personal]

    /// The highest counter of a site.
    public static let maxCounter: UInt32 = .max - 1

    /// Whether the type makes passwords from templates.
    public var isTemplate: Bool { rawValue & Self.classTemplate != 0 }

    /// Whether the type is a password the user stored.
    public var isStateful: Bool { rawValue & Self.classStateful != 0 }

    /// Whether an export keeps the stored password.
    public var isExported: Bool { rawValue & Self.featureExportContent != 0 }

    /// Whether the type is one of Spectre's.
    public var isKnown: Bool { !templates.isEmpty || self == .personal || self == .device || self == .deriveKey }

    /// The type's name, as Spectre shows it.
    public var title: String {
        switch self {
        case .maximum: "Maximum"
        case .long: "Long"
        case .medium: "Medium"
        case .basic: "Basic"
        case .short: "Short"
        case .pin: "PIN"
        case .name: "Name"
        case .phrase: "Phrase"
        case .personal: "Personal"
        case .device: "Device"
        case .deriveKey: "Key"
        default: "Unknown"
        }
    }

    /// The type's templates, of which a site's key picks one.
    var templates: [[UInt8]] { Self.templates[self] ?? [] }

    private static let templates: [ResultType: [[UInt8]]] = {
        let templates: [ResultType: [String]] = [
            .maximum: ["anoxxxxxxxxxxxxxxxxx", "axxxxxxxxxxxxxxxxxno"],
            .long: [
                "CvcvnoCvcvCvcv", "CvcvCvcvnoCvcv", "CvcvCvcvCvcvno",
                "CvccnoCvcvCvcv", "CvccCvcvnoCvcv", "CvccCvcvCvcvno",
                "CvcvnoCvccCvcv", "CvcvCvccnoCvcv", "CvcvCvccCvcvno",
                "CvcvnoCvcvCvcc", "CvcvCvcvnoCvcc", "CvcvCvcvCvccno",
                "CvccnoCvccCvcv", "CvccCvccnoCvcv", "CvccCvccCvcvno",
                "CvcvnoCvccCvcc", "CvcvCvccnoCvcc", "CvcvCvccCvccno",
                "CvccnoCvcvCvcc", "CvccCvcvnoCvcc", "CvccCvcvCvccno",
            ],
            .medium: ["CvcnoCvc", "CvcCvcno"],
            .basic: ["aaanaaan", "aannaaan", "aaannaaa"],
            .short: ["Cvcn"],
            .pin: ["nnnn"],
            .name: ["cvccvcvcv"],
            .phrase: ["cvcc cvc cvccvcv cvc", "cvc cvccvcvcv cvcv", "cv cvccv cvc cvcvccv"],
        ]
        return templates.mapValues { $0.map { Array($0.utf8) } }
    }()

    /// The characters each letter of a template picks from.
    static let characterClasses: [UInt8: [UInt8]] = {
        let classes: [Unicode.Scalar: String] = [
            "V": "AEIOU",
            "C": "BCDFGHJKLMNPQRSTVWXYZ",
            "v": "aeiou",
            "c": "bcdfghjklmnpqrstvwxyz",
            "A": "AEIOUBCDFGHJKLMNPQRSTVWXYZ",
            "a": "AEIOUaeiouBCDFGHJKLMNPQRSTVWXYZbcdfghjklmnpqrstvwxyz",
            "n": "0123456789",
            "o": "@&%?,=[]_:-+*$#!'^~;()/.",
            "x": "AEIOUaeiouBCDFGHJKLMNPQRSTVWXYZbcdfghjklmnpqrstvwxyz0123456789!@#$%^&*()",
            " ": " ",
        ]
        return Dictionary(uniqueKeysWithValues: classes.map { (UInt8(ascii: $0.key), Array($0.value.utf8)) })
    }()
}

extension ResultType: CustomStringConvertible {
    public var description: String { title }
}
