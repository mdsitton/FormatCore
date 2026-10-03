using System;
using System.Collections;
using System.IO;
using internal FormatCore;

namespace FormatCore.Tests;

static class DocumentStorageTests
{
	[Test]
	public static void RangeTable_SideTablesFollowTheItems()
	{
		let random = scope Random(3);
		for (int round < 4)
		{
			let table = scope RangeTable<int32>();
			// A side record per item (its value × 10) in use from the start, and one never used
			let side = scope SideTable<int32>();
			let unused = scope SideTable<int64>();
			var moves = SideMoves<int32, int64>(side, unused);
			const int nodeCount = 6;
			ItemRange[nodeCount] ranges = default;
			let model = scope List<List<int32>>();
			defer { ClearAndDeleteItems!(model); }
			for (int n < nodeCount)
				model.Add(new .());
			// Built in node order, as a reader does
			int32 value = 1;
			for (int n < nodeCount)
			{
				for (int k < random.Next(4))
				{
					table.AddBuilding(ref ranges[n], value);
					side.Add(value * 10);
					model[n].Add(value++);
				}
			}
			for (int step < 400)
			{
				int n = random.Next(nodeCount);
				if (random.Next(3) > 0 || model[n].IsEmpty)
				{
					int at = table.Append(ref ranges[n], value, ref moves);
					side.At(at) = value * 10;
					model[n].Add(value++);
				}
				else
				{
					int index = random.Next(model[n].Count);
					table.RemoveAt(ref ranges[n], index, ref moves);
					model[n].RemoveAt(index);
				}
				for (int m < nodeCount)
				{
					let items = table.Span(ranges[m]);
					Test.Assert(items.Length == model[m].Count && ranges[m].mCapacity >= ranges[m].mCount);
					for (int k < items.Length)
					{
						Test.Assert(items[k] == model[m][k]);
						Test.Assert(side.Get(ranges[m].mStart + k) == model[m][k] * 10);
					}
				}
			}
			Test.Assert(!unused.InUse && side.InUse && side.Count == table.Count);
		}
	}

	[Test]
	public static void SideTable_GrowsAndRemaps()
	{
		let side = scope SideTable<int32>();
		Test.Assert(!side.InUse && side.Get(5) == 0);
		side.ClearAt(3, 10);
		Test.Assert(!side.InUse);
		side.At(4) = 44;
		Test.Assert(side.InUse && side.Count == 5 && side.Get(4) == 44 && side.Get(2) == 0);
		side.At(1) = 11;
		side.At(2) = 22;
		// Old 0..4 → keep 1 at 0, 4 at 1, 2 at 2
		int32[?] newIndexOf = .(-1, 0, 2, -1, 1);
		side.Remap(newIndexOf, 3);
		Test.Assert(side.Count == 3 && side.Get(0) == 11 && side.Get(1) == 44 && side.Get(2) == 22);
		side.Clear();
		Test.Assert(!side.InUse);
		side.At(0) = 1;
		side.Release();
		Test.Assert(!side.InUse);
	}

	static void TempPath(String path, StringView name)
	{
		Directory.GetCurrentDirectory(path);
		path.AppendF("/build/{}", name);
	}

	[Test]
	public static void ReadShell_ReadsWithinTheBudget()
	{
		let path = scope String();
		TempPath(path, "readshell-test.tmp");
		StringView content = "0123456789abcdefghij";
		Test.Assert(File.WriteAllText(path, content) case .Ok);
		defer { File.Delete(path).IgnoreError(); }

		let bytes = scope List<uint8>();
		Test.Assert(ReadShell.ReadFileBytes(path, 0, bytes) case .Ok);
		Test.Assert(StringView((char8*)bytes.Ptr, bytes.Count) == content);
		bytes.Clear();
		Test.Assert(ReadShell.ReadFileBytes(path, 20, bytes) case .Ok);
		bytes.Clear();
		Test.Assert(ReadShell.ReadFileBytes(path, 19, bytes) case .Err(let tooLarge));
		Test.Assert(tooLarge.mKind == .ResourceLimitExceeded && tooLarge.mMessage == "The input (20 bytes) exceeds MaxInputBytes (19)");
		Test.Assert(tooLarge.mLine == 1 && tooLarge.mColumn == 1);

		let missing = scope String();
		TempPath(missing, "readshell-missing.tmp");
		Test.Assert(ReadShell.ReadFileBytes(missing, 0, bytes) case .Err(let notFound) && notFound.mKind == .IoError && notFound.mLine == 0);

		// Into an arena: the document's only copy
		let arena = scope TextArena();
		Test.Assert(ReadShell.ReadFileInto(path, 0, arena) case .Ok(let text) && text == content);
		Test.Assert(ReadShell.ReadFileInto(path, 5, arena) case .Err(let arenaLimit) && arenaLimit.mKind == .ResourceLimitExceeded);
		Test.Assert(ReadShell.ReadFileInto(missing, 0, arena) case .Err(let arenaMissing) && arenaMissing.mKind == .IoError);
		let empty = scope String();
		TempPath(empty, "readshell-empty.tmp");
		Test.Assert(File.WriteAllText(empty, "") case .Ok);
		defer { File.Delete(empty).IgnoreError(); }
		Test.Assert(ReadShell.ReadFileInto(empty, 0, arena) case .Ok(let nothing) && nothing.IsEmpty);
	}

	[Test]
	public static void ReadShell_StreamsWithinTheBudget()
	{
		StringView content = "a stream of some forty bytes, more or so";
		let bytes = scope List<uint8>();
		bytes.Add((uint8)'>');
		let stream = scope ChunkStream(content, 3);
		Test.Assert(ReadShell.ReadStreamBytes(stream, content.Length, bytes, 2) case .Ok);
		// Appended after what was there; the budget counts only the new bytes
		Test.Assert(bytes.Count == content.Length + 1 && StringView((char8*)bytes.Ptr + 1, content.Length) == content);
		bytes.Clear();
		let limited = scope ChunkStream(content, 7);
		Test.Assert(ReadShell.ReadStreamBytes(limited, 10, bytes) case .Err(let tooLarge));
		Test.Assert(tooLarge.mKind == .ResourceLimitExceeded && tooLarge.mMessage == "The input exceeds MaxInputBytes (10)");
		bytes.Clear();
		let failing = scope ChunkStream(content, 4, 9);
		Test.Assert(ReadShell.ReadStreamBytes(failing, 0, bytes) case .Err(let ioError) && ioError.mKind == .IoError);
		Test.Assert(bytes.Count == 9);
	}
}
