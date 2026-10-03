using System;
using System.Collections;
using System.IO;

namespace FormatCore.Testing;

/// @brief Reading test and benchmark inputs: files, directories and standard input, as raw bytes (a
/// byte order mark is kept: the reader under test decides what to do with it).
public static class Inputs
{
	/// @brief A file, or every file under a directory (recursively, sorted by path), one byte list
	/// each (XmlTester's ReadInputs).
	/// @param path The file or directory.
	/// @param inputs Receives the new lists (owned by the caller: `DeleteContainerAndItems!`).
	/// @return Whether every file was read.
	public static Result<void> ReadInputs(StringView path, List<List<uint8>> inputs)
	{
		if (Directory.Exists(path))
		{
			let files = scope List<String>();
			defer { ClearAndDeleteItems!(files); }
			CollectFiles(path, files);
			for (let file in files)
				Try!(ReadOne(file, inputs));
			return .Ok;
		}
		return ReadOne(path, inputs);
	}

	/// @brief Every file under `directory`, recursively, sorted by path (ordinal).
	/// @param directory The directory.
	/// @param files Receives new strings (owned by the caller).
	public static void CollectFiles(StringView directory, List<String> files)
	{
		let found = scope List<String>();
		CollectUnsorted(directory, found);
		found.Sort(scope (a, b) => String.Compare(a, b, false));
		files.AddRange(found);
	}

	static void CollectUnsorted(StringView directory, List<String> files)
	{
		for (let entry in Directory.EnumerateFiles(directory))
			files.Add(entry.GetFilePath(.. new .()));
		for (let entry in Directory.EnumerateDirectories(directory))
			CollectUnsorted(entry.GetFilePath(.. scope .()), files);
	}

	/// @brief One file's bytes, added to `inputs` as a new list.
	/// @param path The file.
	/// @param inputs Receives the new list (owned by the caller).
	/// @return Whether the file was read.
	public static Result<void> ReadOne(StringView path, List<List<uint8>> inputs)
	{
		let bytes = new List<uint8>();
		if (File.ReadAll(path, bytes) case .Err)
		{
			delete bytes;
			return .Err;
		}
		inputs.Add(bytes);
		return .Ok;
	}

	/// @brief Everything a stream holds, appended as bytes.
	/// @param stream The stream.
	/// @param bytes Receives the bytes.
	/// @return Whether the stream was read to its end.
	public static Result<void> ReadAll(Stream stream, List<uint8> bytes)
	{
		uint8[65536] chunk = ?;
		while (true)
		{
			switch (stream.TryRead(.(&chunk, chunk.Count)))
			{
			case .Ok(let count):
				if (count <= 0)
					return .Ok;
				bytes.AddRange(Span<uint8>(&chunk, count));
			case .Err:
				return .Err;
			}
		}
	}

	/// @brief Everything a stream holds, appended as text bytes (not decoded, a BOM kept).
	/// @param stream The stream.
	/// @param output Receives the bytes.
	/// @return Whether the stream was read to its end.
	public static Result<void> ReadAll(Stream stream, String output)
	{
		uint8[65536] chunk = ?;
		while (true)
		{
			switch (stream.TryRead(.(&chunk, chunk.Count)))
			{
			case .Ok(let count):
				if (count <= 0)
					return .Ok;
				output.Append((char8*)&chunk, count);
			case .Err:
				return .Err;
			}
		}
	}

	/// @brief Standard input as bytes (Console.In.ReadToEnd would decode it and drop a BOM).
	/// @param bytes Receives the bytes.
	/// @return Whether it was read to its end.
	public static Result<void> ReadStdin(List<uint8> bytes) => ReadAll(Console.In.BaseStream, bytes);

	/// @brief Standard input as text bytes (not decoded, a BOM kept).
	/// @param output Receives the bytes.
	/// @return Whether it was read to its end.
	public static Result<void> ReadStdin(String output) => ReadAll(Console.In.BaseStream, output);
}

/// @brief A read-only stream over borrowed bytes that returns at most `chunk` bytes per read, and can
/// fail with an I/O error after `failAfter` bytes: the 1-31-byte sweeps that prove a stream reader
/// agrees with the in-memory one at every refill boundary.
public class ChunkStream : Stream
{
	Span<uint8> mData;
	int mPos;
	int mChunk;
	int mFailAfter;

	/// @brief A stream over `data` (borrowed: it must outlive the stream).
	/// @param data The bytes.
	/// @param chunk The most bytes one read returns (at least 1).
	/// @param failAfter Fail every read once this many bytes were returned (-1: never).
	public this(Span<uint8> data, int chunk, int failAfter = -1)
	{
		mData = data;
		mChunk = Math.Max(chunk, 1);
		mFailAfter = failAfter;
	}

	/// @brief A stream over text bytes (borrowed).
	/// @param text The bytes.
	/// @param chunk The most bytes one read returns (at least 1).
	/// @param failAfter Fail every read once this many bytes were returned (-1: never).
	public this(StringView text, int chunk, int failAfter = -1) : this(Span<uint8>((uint8*)text.Ptr, text.Length), chunk, failAfter)
	{
	}

	static int[31] sSweepSizes = .(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);

	/// @brief The chunk sizes of a full sweep: 1 to 31 bytes per read.
	public static Span<int> SweepSizes => .(&sSweepSizes, sSweepSizes.Count);

	public override int64 Position
	{
		get => mPos;
		set => mPos = (int)Math.Clamp(value, 0, mData.Length);
	}

	public override int64 Length => mData.Length;
	public override bool CanRead => true;
	public override bool CanWrite => false;

	public override Result<int> TryRead(Span<uint8> data)
	{
		if (mFailAfter >= 0 && mPos >= mFailAfter)
			return .Err;
		int limit = mFailAfter >= 0 ? Math.Min(mData.Length, mFailAfter) : mData.Length;
		int count = Math.Min(Math.Min(data.Length, mChunk), limit - mPos);
		if (count <= 0)
			return .Ok(0);
		Internal.MemCpy(data.Ptr, mData.Ptr + mPos, count);
		mPos += count;
		return count;
	}

	public override Result<int> TryWrite(Span<uint8> data) => .Err;
	public override Result<void> Close() => .Ok;
}
