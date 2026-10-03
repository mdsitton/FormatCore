using System;
using System.Collections;
using System.IO;
using internal FormatCore;

namespace FormatCore;

/// Reading a whole input before parsing it, within a size budget (KdlBeef's and XmlBeef's
/// ReadFileBytes/ReadStreamBytes, JsonBeef's read straight into its arena). Failures are InputErrors
/// (IoError, ResourceLimitExceeded): the format maps the kind, names the source and clears its document.
/// A size error is located at 1:1 (offset 0), an I/O error has no position (line 0).
internal static class ReadShell
{
	/// @brief Read a whole file into `bytes` (appended), but with a `maxInputBytes` budget never more
	/// than that: a larger file fails from its size before anything is read, and one that grows while it
	/// is read stops at the limit.
	/// @param path The file's path.
	/// @param maxInputBytes The budget (0: no limit).
	/// @param bytes Receives the bytes.
	/// @return .Ok, or the error.
	public static Result<void, InputError> ReadFileBytes(StringView path, int maxInputBytes, List<uint8> bytes)
	{
		let file = scope FileStream();
		if (file.Open(path, .Read, .Read) case .Err)
			return .Err(InputError(.IoError, "Cannot read the file", 0, 0, 0, 0));
		int64 size = file.Length;
		if (maxInputBytes > 0 && size > maxInputBytes)
			return .Err(TooLarge(size, maxInputBytes));
		// The expected size in one read (plus a byte to see the end), then more if the file grew
		return ReadStreamBytes(file, maxInputBytes, bytes, (int)size + 1);
	}

	/// @brief Read a stream to its end into `bytes` (appended), failing past `maxInputBytes`.
	/// @param stream The stream.
	/// @param maxInputBytes The budget (0: no limit).
	/// @param bytes Receives the bytes.
	/// @param firstChunk The size of the first read.
	/// @return .Ok, or the error.
	public static Result<void, InputError> ReadStreamBytes(Stream stream, int maxInputBytes, List<uint8> bytes, int firstChunk = 65536)
	{
		int chunk = Math.Max(firstChunk, 1);
		int start = bytes.Count;
		while (true)
		{
			int filled = bytes.Count;
			bytes.Count = filled + chunk;
			switch (stream.TryRead(.(bytes.Ptr + filled, chunk)))
			{
			case .Ok(let read):
				bytes.Count = filled + Math.Max(read, 0);
				if (read <= 0)
					return .Ok;
				if (maxInputBytes > 0 && bytes.Count - start > maxInputBytes)
					return .Err(InputError(.ResourceLimitExceeded, scope $"The input exceeds MaxInputBytes ({maxInputBytes})", 1, 1, 0, 0));
				chunk = Math.Max(chunk - read, 4096);
			case .Err:
				bytes.Count = filled;
				return .Err(InputError(.IoError, "Cannot read the input", 0, 0, 0, 0));
			}
		}
	}

	/// @brief Read a whole file straight into `arena` (JsonBeef's ReadFile: the document's only copy).
	/// The file's size at opening is what is read; a file that is shorter by then is an I/O error.
	/// @param path The file's path.
	/// @param maxInputBytes The budget (0: no limit).
	/// @param arena Where the bytes go.
	/// @return A view of the bytes in the arena, or the error.
	public static Result<StringView, InputError> ReadFileInto(StringView path, int maxInputBytes, TextArena arena)
	{
		let file = scope FileStream();
		if (file.Open(path, .Read, .Read) case .Err)
			return .Err(InputError(.IoError, "Cannot read the file", 0, 0, 0, 0));
		int64 length = file.Length;
		if (maxInputBytes > 0 && length > maxInputBytes)
			return .Err(TooLarge(length, maxInputBytes));
		if (length == 0)
			return StringView(arena.Alloc(0), 0);
		char8* bytes = arena.Alloc((int)length);
		int filled = 0;
		while (filled < length)
		{
			switch (file.TryRead(.((uint8*)bytes + filled, (int)length - filled)))
			{
			case .Ok(let read):
				if (read <= 0)
					return .Err(InputError(.IoError, "The file ended before its size", 0, 0, 0, 0));
				filled += read;
			case .Err:
				return .Err(InputError(.IoError, "Cannot read the file", 0, 0, 0, 0));
			}
		}
		return StringView(bytes, filled);
	}

	static InputError TooLarge(int64 size, int maxInputBytes)
	{
		return InputError(.ResourceLimitExceeded, scope $"The input ({size} bytes) exceeds MaxInputBytes ({maxInputBytes})", 1, 1, 0, 0);
	}
}
