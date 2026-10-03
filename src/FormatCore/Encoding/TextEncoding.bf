using System;
using internal FormatCore;

namespace FormatCore;

/// @brief A character encoding a document can be read in (XmlBeef's XmlEncoding, format-free). A format
/// that exposes it names it its own way: `public typealias XmlEncoding = FormatCore.TextEncoding;`.
public enum TextEncoding : uint8
{
	/// @brief UTF-8, with or without a byte order mark (read as is, no transcoding).
	case Utf8;
	/// @brief UTF-16, little-endian.
	case Utf16LE;
	/// @brief UTF-16, big-endian.
	case Utf16BE;
	/// @brief UTF-32 (UCS-4), little-endian.
	case Utf32LE;
	/// @brief UTF-32 (UCS-4), big-endian.
	case Utf32BE;
	/// @brief ISO-8859-1 (Latin-1): bytes are code points.
	case Latin1;
	/// @brief US-ASCII.
	case Ascii;
	/// @brief A legacy encoding converted to UTF-8 by an EncodingConverter.
	case Custom;
	// Single-byte encodings, decoded through tables (SingleByteTables.bf, generated from the WHATWG
	// Encoding Standard's indexes by tools/gen-encoding-tables.py)
	/// @brief IBM866 (DOS Cyrillic).
	case Ibm866;
	/// @brief ISO-8859-2 (Latin-2, Central European).
	case Iso8859_2;
	/// @brief ISO-8859-3 (Latin-3, South European).
	case Iso8859_3;
	/// @brief ISO-8859-4 (Latin-4, North European).
	case Iso8859_4;
	/// @brief ISO-8859-5 (Cyrillic).
	case Iso8859_5;
	/// @brief ISO-8859-6 (Arabic).
	case Iso8859_6;
	/// @brief ISO-8859-7 (Greek).
	case Iso8859_7;
	/// @brief ISO-8859-8 (Hebrew; also ISO-8859-8-I).
	case Iso8859_8;
	/// @brief ISO-8859-9 (Latin-5, Turkish).
	case Iso8859_9;
	/// @brief ISO-8859-10 (Latin-6, Nordic).
	case Iso8859_10;
	/// @brief ISO-8859-11 (Thai; also TIS-620).
	case Iso8859_11;
	/// @brief ISO-8859-13 (Latin-7, Baltic).
	case Iso8859_13;
	/// @brief ISO-8859-14 (Latin-8, Celtic).
	case Iso8859_14;
	/// @brief ISO-8859-15 (Latin-9).
	case Iso8859_15;
	/// @brief ISO-8859-16 (Latin-10, South-Eastern European).
	case Iso8859_16;
	/// @brief KOI8-R (Russian).
	case Koi8R;
	/// @brief KOI8-U (Ukrainian).
	case Koi8U;
	/// @brief Mac OS Roman (`macintosh`).
	case Macintosh;
	/// @brief Mac OS Cyrillic (`x-mac-cyrillic`).
	case MacCyrillic;
	/// @brief Windows-874 (Thai).
	case Windows874;
	/// @brief Windows-1250 (Central European).
	case Windows1250;
	/// @brief Windows-1251 (Cyrillic).
	case Windows1251;
	/// @brief Windows-1252 (Western European).
	case Windows1252;
	/// @brief Windows-1253 (Greek).
	case Windows1253;
	/// @brief Windows-1254 (Turkish).
	case Windows1254;
	/// @brief Windows-1255 (Hebrew).
	case Windows1255;
	/// @brief Windows-1256 (Arabic).
	case Windows1256;
	/// @brief Windows-1257 (Baltic).
	case Windows1257;
	/// @brief Windows-1258 (Vietnamese).
	case Windows1258;

	/// @brief Whether the encoding is UTF-16 or UTF-32 (either byte order).
	public bool IsWide => this >= .Utf16LE && this <= .Utf32BE;

	/// @brief Whether the encoding maps each byte to one character (Latin-1, US-ASCII, the tables).
	public bool IsSingleByte => this == .Latin1 || this == .Ascii || this >= .Ibm866;

	/// @brief The encoding's name for messages: the IANA/WHATWG name (`UTF-16LE`, `windows-1252`).
	public StringView Name
	{
		get
		{
			switch (this)
			{
			case .Utf8: return "UTF-8";
			case .Utf16LE: return "UTF-16LE";
			case .Utf16BE: return "UTF-16BE";
			case .Utf32LE: return "UTF-32LE";
			case .Utf32BE: return "UTF-32BE";
			case .Latin1: return "ISO-8859-1";
			case .Ascii: return "US-ASCII";
			case .Custom: return "a converted encoding";
			case .Ibm866: return "IBM866";
			case .Iso8859_2: return "ISO-8859-2";
			case .Iso8859_3: return "ISO-8859-3";
			case .Iso8859_4: return "ISO-8859-4";
			case .Iso8859_5: return "ISO-8859-5";
			case .Iso8859_6: return "ISO-8859-6";
			case .Iso8859_7: return "ISO-8859-7";
			case .Iso8859_8: return "ISO-8859-8";
			case .Iso8859_9: return "ISO-8859-9";
			case .Iso8859_10: return "ISO-8859-10";
			case .Iso8859_11: return "ISO-8859-11";
			case .Iso8859_13: return "ISO-8859-13";
			case .Iso8859_14: return "ISO-8859-14";
			case .Iso8859_15: return "ISO-8859-15";
			case .Iso8859_16: return "ISO-8859-16";
			case .Koi8R: return "KOI8-R";
			case .Koi8U: return "KOI8-U";
			case .Macintosh: return "macintosh";
			case .MacCyrillic: return "x-mac-cyrillic";
			case .Windows874: return "windows-874";
			case .Windows1250: return "windows-1250";
			case .Windows1251: return "windows-1251";
			case .Windows1252: return "windows-1252";
			case .Windows1253: return "windows-1253";
			case .Windows1254: return "windows-1254";
			case .Windows1255: return "windows-1255";
			case .Windows1256: return "windows-1256";
			case .Windows1257: return "windows-1257";
			case .Windows1258: return "windows-1258";
			}
		}
	}

	/// @brief The encoding an encoding name (label) names, case-insensitively, when it names exactly one:
	/// `utf-16` and `utf-32` without a byte order do not (EncodingLabels.Classify tells the family), nor
	/// do unknown names. ISO-8859-1 and US-ASCII labels name those (IANA's reading, not WHATWG's
	/// windows-1252).
	/// @param label The name, as written.
	/// @param encoding Receives the encoding.
	/// @return Whether the label names one encoding.
	public static bool FromLabel(StringView label, out TextEncoding encoding)
	{
		switch (EncodingLabels.Classify(label, out encoding))
		{
		case .Utf8: encoding = .Utf8;
		case .Utf16LE: encoding = .Utf16LE;
		case .Utf16BE: encoding = .Utf16BE;
		case .Utf32LE: encoding = .Utf32LE;
		case .Utf32BE: encoding = .Utf32BE;
		case .Latin1: encoding = .Latin1;
		case .Ascii: encoding = .Ascii;
		case .SingleByte: // Classify set the table's encoding
		default:
			encoding = .Utf8;
			return false;
		}
		return true;
	}
}

/// @brief What to do with input that has no byte order mark and no declared encoding but is not valid
/// UTF-8.
public enum EncodingFallback : uint8
{
	/// @brief Report it: an encoding error.
	None,
	/// @brief Read it as Windows-1252, a superset of Latin-1's printable range: how hand-edited files in
	/// the wild usually turn out to be encoded (the author's StrikeCore heuristic).
	Windows1252
}

/// @brief Converts input in a legacy encoding FormatCore does not decode itself (Shift_JIS, EUC-JP, GBK,
/// Big5, EUC-KR, …) to UTF-8.
/// @param encodingName The encoding's name as the input declares it.
/// @param input The input's bytes.
/// @param output Receives the input as UTF-8.
/// @return Whether the encoding was converted; false makes it an UnsupportedEncoding error.
public delegate bool EncodingConverter(StringView encodingName, Span<uint8> input, String output);

/// What an encoding name names: a family when the byte order is left to a byte order mark.
internal enum EncodingFamily : uint8
{
	/// No name.
	None,
	/// A name FormatCore does not decode (a converter's).
	Unknown,
	Utf8,
	/// UTF-16 in either byte order.
	Utf16,
	Utf16LE,
	Utf16BE,
	/// UTF-32 in either byte order.
	Utf32,
	Utf32LE,
	Utf32BE,
	Latin1,
	Ascii,
	/// One of the table-driven encodings.
	SingleByte
}

/// The encoding labels (XmlBeef's Classify): WHATWG's for the single-byte encodings, the IANA names for
/// the Unicode ones, ISO-8859-1 and US-ASCII.
internal static class EncodingLabels
{
	/// @brief The family an encoding name names (case-insensitive).
	/// @param name The name, as written.
	/// @param single Receives the encoding of a single-byte family (SingleByte), else Utf8.
	/// @return The family (None for an empty name, Unknown for a name not decoded here).
	public static EncodingFamily Classify(StringView name, out TextEncoding single)
	{
		single = .Utf8;
		if (name.IsEmpty)
			return .None;
		let lower = scope String(name);
		lower.ToLower();
		// The common case before the table, whose 154-case string switch is a chain of compares
		if (lower == "utf-8")
			return .Utf8;
		if (SingleByteLabels.TryGet(lower, out single))
			return .SingleByte;
		switch (lower)
		{
		case "utf-8", "utf8":
			return .Utf8;
		case "utf-16", "ucs-2", "iso-10646-ucs-2", "csunicode", "unicode":
			return .Utf16;
		case "utf-16le":
			return .Utf16LE;
		case "utf-16be":
			return .Utf16BE;
		case "utf-32", "ucs-4", "iso-10646-ucs-4", "csucs4":
			return .Utf32;
		case "utf-32le":
			return .Utf32LE;
		case "utf-32be":
			return .Utf32BE;
		case "iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "latin1", "l1", "iso-ir-100", "cp819", "ibm819", "csisolatin1":
			return .Latin1;
		case "us-ascii", "ascii", "iso646-us", "ansi_x3.4-1968", "cp367", "ibm367", "csascii":
			return .Ascii;
		default:
			return .Unknown;
		}
	}
}
