using System;
using internal FormatCore;

namespace FormatCore;

/// What an encoding detector found at the start of an input.
internal struct EncodingDetection
{
	/// The decoder to use (Utf8: the bytes are read as they are; Custom: the converter's).
	public TextEncoding mEncoding;
	/// Bytes of a UTF-16 or UTF-32 byte order mark, skipped before decoding.
	public int mSkip;
	/// The text starts with a UTF-8 byte order mark, kept: its content starts at offset 3.
	public bool mUtf8Bom;
	/// Nothing named the encoding (no byte order mark, no byte pattern, no declaration): UTF-8, or with
	/// EncodingFallback.Windows1252 Windows-1252 when the whole input is not valid UTF-8.
	public bool mUndeclared;
	/// The declared encoding is for the EncodingConverter (`declared` holds its name).
	public bool mConvert;
	/// The prefix ended before the encoding was known (inside a declaration): detect again with more
	/// of the input, unless that was all of it.
	public bool mIncomplete;
	/// A note the detector passes through for the format (XmlBeef: a UTF-8 byte order mark overrode an
	/// 8-bit declaration).
	public bool mBomOverride;
	/// Where the declared name is in the input (for an unsupported-encoding error), or -1.
	public int mNameOffset = -1;
	public int mNameLength;

	public this()
	{
		this = default;
		mNameOffset = -1;
	}
}

/// A format's encoding detection, at compile time: a struct passed as a generic argument to the
/// transcoding cursors (never a delegate). FormatCore's BomDetector covers formats whose encoding is
/// shown only by a byte order mark or byte patterns; XmlBeef's adds the XML declaration.
internal interface IEncodingDetector
{
	/// How many bytes detection reads first (more while it says the prefix is incomplete).
	static int PrefixBytes { get; }

	/// Detects the encoding from the input's first bytes.
	/// @param prefix The input's first bytes (all of it if shorter than PrefixBytes).
	/// @param declared Receives the declared encoding's name (empty if none).
	/// @param scratch Scratch space (e.g. a wide prefix decoded, to read a declaration).
	/// @return What was found, or an error (UnsupportedEncoding) for an encoding the input cannot be in.
	static Result<EncodingDetection, InputError> Detect(StringView prefix, String declared, String scratch);

	/// Appends the message for a prefix that grew to MaxTokenBytes without the encoding being known.
	static void AppendUndecided(String message, int maxTokenBytes);
}

/// Byte order marks and byte patterns: what a format with no encoding declaration can know about its
/// input's encoding (XmlBeef's detector without the XML declaration, JsonBeef's DetectWideEncoding).
internal static class Bom
{
	/// @brief Detects the encoding from the first bytes: UTF-32 and UTF-16 byte order marks (UTF-32's
	/// first: FF FE 00 00 starts like FF FE), the UTF-8 one (kept), UTF-7's and EBCDIC's rejected, then
	/// the zero bytes of characters below U+0100 in 16- and 32-bit units (RFC 4627 §3); anything else is
	/// undeclared (UTF-8 unless a fallback applies).
	/// @param prefix The input's first bytes (at least 4, or all of it).
	/// @return What was found, or an UnsupportedEncoding error located at 1:1.
	public static Result<EncodingDetection, InputError> Detect(StringView prefix)
	{
		uint8* b = (uint8*)prefix.Ptr;
		int n = prefix.Length;
		EncodingDetection detection = .();
		detection.mEncoding = .Utf8;
		if (n >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFE && b[3] == 0xFF)
			return Wide(.Utf32BE, 4);
		if (n >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0x00 && b[3] == 0x00)
			return Wide(.Utf32LE, 4);
		if (n >= 4 && ((b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFF && b[3] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF && b[2] == 0x00 && b[3] == 0x00)))
			return .Err(InputError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
		if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF)
			return Wide(.Utf16BE, 2);
		if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
			return Wide(.Utf16LE, 2);
		if (Utf8.StartsWithBom(prefix.Ptr, n))
		{
			detection.mUtf8Bom = true;
			return detection;
		}
		if (n >= 4 && b[0] == 0x2B && b[1] == 0x2F && b[2] == 0x76 && (b[3] == 0x38 || b[3] == 0x39 || b[3] == 0x2B || b[3] == 0x2F))
			return .Err(InputError(.UnsupportedEncoding, "UTF-7 is not supported", 1, 1, 0, 4));
		if (n >= 4)
		{
			// `<?xm` in EBCDIC: the one EBCDIC start a document shows by its bytes
			if (b[0] == 0x4C && b[1] == 0x6F && b[2] == 0xA7 && b[3] == 0x94)
				return .Err(InputError(.UnsupportedEncoding, "EBCDIC encodings are not supported", 1, 1, 0, 4));
			if (b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] != 0)
				return Wide(.Utf32BE, 0);
			if (b[0] != 0 && b[1] == 0 && b[2] == 0 && b[3] == 0)
				return Wide(.Utf32LE, 0);
			if ((b[0] == 0 && b[1] == 0 && b[2] != 0 && b[3] == 0) || (b[0] == 0 && b[1] != 0 && b[2] == 0 && b[3] == 0))
				return .Err(InputError(.UnsupportedEncoding, "UCS-4 in the unusual byte orders 2143 and 3412 is not supported", 1, 1, 0, 4));
			if (b[0] == 0 && b[1] != 0 && b[2] == 0 && b[3] != 0)
				return Wide(.Utf16BE, 0);
			if (b[0] != 0 && b[1] == 0 && b[2] != 0 && b[3] == 0)
				return Wide(.Utf16LE, 0);
		}
		detection.mUndeclared = true;
		return detection;
	}

	/// @brief Detects the encoding as YAML does (YAML 1.2.2 §5.2), from the first character alone: a
	/// UTF-32 or UTF-16 byte order mark, or the zero bytes around a first character that must be ASCII
	/// (`00 00 00 xx` UTF-32BE, `xx 00 00 00` UTF-32LE, `00 xx` UTF-16BE, `xx 00` UTF-16LE), the UTF-8
	/// byte order mark (kept), else UTF-8. Unlike Detect, it needs no second ASCII character, so a
	/// one-character UTF-16 document, or one whose second character is above U+00FF (`a中`), is found.
	/// @param prefix The input's first bytes (at least 4, or all of it).
	/// @return What was found (never an error: every prefix maps to an encoding).
	public static EncodingDetection DetectFirstCharacter(StringView prefix)
	{
		uint8* b = (uint8*)prefix.Ptr;
		int n = prefix.Length;
		if (n >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0xFE && b[3] == 0xFF)
			return Wide(.Utf32BE, 4);
		if (n >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x00)
			return Wide(.Utf32BE, 0);
		if (n >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0x00 && b[3] == 0x00)
			return Wide(.Utf32LE, 4);
		if (n >= 4 && b[0] != 0x00 && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00)
			return Wide(.Utf32LE, 0);
		if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF)
			return Wide(.Utf16BE, 2);
		if (n >= 2 && b[0] == 0x00)
			return Wide(.Utf16BE, 0);
		if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
			return Wide(.Utf16LE, 2);
		if (n >= 2 && b[1] == 0x00)
			return Wide(.Utf16LE, 0);
		EncodingDetection detection = .();
		detection.mEncoding = .Utf8;
		if (Utf8.StartsWithBom(prefix.Ptr, n))
			detection.mUtf8Bom = true;
		else
			detection.mUndeclared = true;
		return detection;
	}

	static EncodingDetection Wide(TextEncoding encoding, int skip)
	{
		EncodingDetection detection = .();
		detection.mEncoding = encoding;
		detection.mSkip = skip;
		return detection;
	}
}

/// The detector of a format without an encoding declaration: Bom.Detect on the first 4 bytes.
internal struct BomDetector : IEncodingDetector
{
	public static int PrefixBytes
	{
		[Inline]
		get => 4;
	}

	public static Result<EncodingDetection, InputError> Detect(StringView prefix, String declared, String scratch)
	{
		declared.Clear();
		return Bom.Detect(prefix);
	}

	public static void AppendUndecided(String message, int maxTokenBytes)
	{
		message.AppendF("The input's encoding is not known after MaxTokenBytes ({})", maxTokenBytes);
	}
}

/// The detector of a format whose input's first character shows its encoding (YAML 1.2.2 §5.2):
/// Bom.DetectFirstCharacter on the first 4 bytes.
internal struct FirstCharacterDetector : IEncodingDetector
{
	public static int PrefixBytes
	{
		[Inline]
		get => 4;
	}

	public static Result<EncodingDetection, InputError> Detect(StringView prefix, String declared, String scratch)
	{
		declared.Clear();
		return Bom.DetectFirstCharacter(prefix);
	}

	public static void AppendUndecided(String message, int maxTokenBytes)
	{
		message.AppendF("The input's encoding is not known after MaxTokenBytes ({})", maxTokenBytes);
	}
}

/// What a transcoding read needs beyond InputSettings: the converter for encodings FormatCore does not
/// decode, and the fallback for undeclared input that is not UTF-8. Both are borrowed.
internal struct TranscodeSettings
{
	public EncodingFallback mFallback;
	public EncodingConverter mConverter;
}

/// The in-memory side of transcoding (XmlBeef's XmlEncodingDetector.Prepare without the declaration
/// logic, which a detector supplies): detect, convert or fall back, and decode the whole input into
/// UTF-8 at once.
internal static class Transcoding
{
	/// @brief Detect the encoding of a whole in-memory input and make its UTF-8 text.
	/// @param input The input's bytes.
	/// @param buffer Receives the transcoded text when the input is not UTF-8.
	/// @param settings MaxTokenBytes (bounds the detection prefix) and the BOM policy.
	/// @param transcode The converter and the fallback.
	/// @param declared Receives the declared encoding's name (empty if none).
	/// @param scratch Scratch space for the detector.
	/// @param text Receives the UTF-8 text: `input`, or a view of `buffer`.
	/// @param start Receives the offset of the first content byte in `text` (after a UTF-8 BOM).
	/// @param detection Receives what was detected; its mEncoding is the encoding read in (after a
	/// fallback).
	/// @return An error for an unsupported encoding, a rejected BOM, or bytes invalid in the encoding
	/// (located in the decoded text, under the format's newline rules).
	public static Result<void, InputError> Prepare<TText, TDetect>(StringView input, String buffer, InputSettings settings, TranscodeSettings transcode,
		String declared, String scratch, out StringView text, out int start, out EncodingDetection detection)
		where TText : ITextPolicy where TDetect : IEncodingDetector
	{
		text = input;
		start = 0;
		// The prefix a stream sees, not the whole input, grown while the detector needs more
		int probe = TDetect.PrefixBytes;
		while (true)
		{
			switch (TDetect.Detect(input.Substring(0, Math.Min(input.Length, probe)), declared, scratch))
			{
			case .Ok(let found):
				detection = found;
			case .Err(let error):
				detection = .();
				return .Err(error);
			}
			if (!detection.mIncomplete || probe >= input.Length)
				break;
			Try!(CheckPrefixLength<TDetect>(probe, settings));
			probe *= 2;
		}
		if (detection.mUtf8Bom)
		{
			start = 3;
			if (settings.mBom == .Reject)
				return .Err(InputError(.ByteOrderMark, "A byte order mark (U+FEFF) is not allowed", 1, 1, 0, 3));
		}
		if (detection.mConvert)
		{
			buffer.Clear();
			if (transcode.mConverter != null && transcode.mConverter(declared, Span<uint8>((uint8*)input.Ptr, input.Length), buffer))
			{
				text = buffer;
				detection.mEncoding = .Custom;
				start = Utf8.StartsWithBom(buffer.Ptr, buffer.Length) ? 3 : 0;
				return .Ok;
			}
			return .Err(Unsupported<TText>(input, declared, detection));
		}
		if (detection.mUndeclared && transcode.mFallback == .Windows1252 && !IsValidUtf8(input))
			detection.mEncoding = .Windows1252;
		if (detection.mEncoding == .Utf8)
			return .Ok;
		// Transcode it all at once, into a buffer sized for the worst case
		var decoder = Decoder(detection.mEncoding);
		int length = input.Length - detection.mSkip;
		int capacity = length * decoder.MaxExpansion + 8;
		buffer.Clear();
		uint8* dst = (uint8*)buffer.PrepareBuffer(capacity);
		bool ok = decoder.Decode((uint8*)input.Ptr + detection.mSkip, length, true, dst, capacity, let consumed, let produced, let error);
		buffer.Length = produced;
		text = buffer;
		if (!ok)
			return .Err(DecodeError<TText>(error, detection.mEncoding, declared, (uint8)input[detection.mSkip + consumed], buffer, produced));
		return .Ok;
	}

	/// @brief The error for a detection prefix that reached MaxTokenBytes still incomplete.
	/// @param probed The prefix's length so far.
	/// @param settings The settings.
	/// @return An error past the limit.
	public static Result<void, InputError> CheckPrefixLength<TDetect>(int probed, InputSettings settings) where TDetect : IEncodingDetector
	{
		if (settings.mMaxTokenBytes > 0 && probed >= settings.mMaxTokenBytes)
		{
			let message = scope String();
			TDetect.AppendUndecided(message, settings.mMaxTokenBytes);
			return .Err(InputError(.ResourceLimitExceeded, message, 1, 1, 0, 0));
		}
		return .Ok;
	}

	/// @brief A decoding error at the end of what was decoded (`produced` bytes of `text`), located in
	/// the decoded text.
	/// @param error The decoder's message.
	/// @param encoding The encoding.
	/// @param declared The declared name (empty: the encoding's own name).
	/// @param badByte The byte at fault.
	/// @param text The decoded text.
	/// @param produced Where the error is in it.
	/// @return The error.
	public static InputError DecodeError<TText>(StringView error, TextEncoding encoding, StringView declared, uint8 badByte, StringView text, int produced)
		where TText : ITextPolicy
	{
		let message = scope String();
		Decoder.AppendError(message, error, encoding, declared, badByte);
		Utf8.LineAndColumn<TText>(text, produced, let line, let column);
		return InputError(.InvalidEncoding, message, line, column, produced, 1);
	}

	/// @brief The error for an encoding no decoder or converter takes, at its declared name.
	/// @param input The input (ASCII-compatible where the name is).
	/// @param declared The name.
	/// @param detection Where the name is.
	/// @return The error.
	public static InputError Unsupported<TText>(StringView input, StringView declared, EncodingDetection detection) where TText : ITextPolicy
	{
		let message = scope String();
		message.AppendF("The encoding `{}` is not supported", declared);
		if (detection.mNameOffset < 0)
			return InputError(.UnsupportedEncoding, message, 1, 1, 0, 0);
		Utf8.LineAndColumn<TText>(input, detection.mNameOffset, let line, let column);
		return InputError(.UnsupportedEncoding, message, line, column, detection.mNameOffset, detection.mNameLength);
	}

	/// @brief Whether `input` is well-formed UTF-8 (the fallback's test; a format's bans are checked
	/// later either way).
	/// @param input The input.
	/// @return Whether it is.
	public static bool IsValidUtf8(StringView input)
	{
		return Utf8.FindInvalid<PlainUtf8Text>(input.Ptr, 0, input.Length, scope String(), ?, ?) < 0;
	}
}
