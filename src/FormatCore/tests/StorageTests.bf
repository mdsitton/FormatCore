using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore.Tests;

static class StorageTests
{
	[Test]
	public static void GrowList_GrowsAndTrims()
	{
		let list = scope GrowList<int32>(1);
		for (int32 i < 100)
			list.Add(i);
		Test.Assert(list.Count == 100 && list.Capacity >= 100 && list[57] == 57 && list.Back == 99);
		Test.Assert(list.PopBack() == 99 && list.Count == 99);
		list.AddDefault() = 7;
		Test.Assert(list.Back == 7);
		// GrowUninitialized(0) at full capacity points one past the end
		let full = scope GrowList<int32>(4);
		for (int32 i < 4)
			full.Add(i);
		int32* end = full.GrowUninitialized(0);
		Test.Assert(end == full.Ptr + 4 && full.Count == 4);
		int32* more = full.GrowUninitialized(3);
		more[0] = 10;
		more[2] = 12;
		Test.Assert(full.Count == 7 && full[4] == 10 && full[6] == 12 && full[3] == 3);
		list.Count = 5;
		list.TrimExcess(2);
		Test.Assert(list.Capacity == 5 && list[4] == 4);
		Test.Assert(list.Span.Length == 5 && list.ReservedBytes == 20);
		list.Clear();
		list.TrimExcess(0);
		Test.Assert(list.Capacity == 1 && list.IsEmpty);
	}

	[Test]
	public static void BitStack_PushesPastOneWord()
	{
		var bits = BitStack();
		defer bits.Dispose();
		let reference = scope List<bool>();
		let random = scope Random(5);
		for (int round < 2000)
		{
			if (reference.Count > 0 && random.Next(3) == 0)
			{
				Test.Assert(bits.Pop() == reference.PopBack());
				continue;
			}
			bool bit = random.Next(2) == 1;
			bits.Push(bit);
			reference.Add(bit);
			Test.Assert(bits.Top == bit && bits.Depth == reference.Count);
		}
		while (reference.Count > 0)
			Test.Assert(bits.Pop() == reference.PopBack());
	}

	[Test]
	public static void DecodeBuffer_GrowsKeepingTheBytes()
	{
		let buffer = scope DecodeBuffer(16);
		char8* dest = buffer.Ptr;
		char8* limit = buffer.Limit;
		StringView chunk = "0123456789abcdefXYZ";
		for (int i < 20)
		{
			if (dest + chunk.Length + 16 > limit)
				buffer.Grow(ref dest, ref limit, chunk.Length + 16);
			DecodeBuffer.CopyRun(dest, chunk.Ptr, chunk.Length, false);
			dest += chunk.Length;
			DecodeBuffer.CopyRun(dest, chunk.Ptr, 5, true);
			dest += 5;
		}
		Test.Assert(dest - buffer.Ptr == 20 * 24);
		for (int i < 20)
		{
			Test.Assert(StringView(buffer.Ptr + i * 24, 19) == chunk);
			Test.Assert(StringView(buffer.Ptr + i * 24 + 19, 5) == "01234");
		}
	}

	[Test]
	public static void TextArena_ReusesChunksAfterReset()
	{
		let arena = scope TextArena(64);
		let copies = scope List<StringView>();
		for (int i < 200)
			copies.Add(arena.Copy(scope $"text number {i}"));
		for (int i < 200)
			Test.Assert(copies[i] == scope $"text number {i}");
		int reserved = arena.ReservedBytes;
		Test.Assert(arena.FilledBytes > 0 && arena.FilledBytes <= reserved);
		// The same work after a reset allocates no chunk
		arena.Reset();
		Test.Assert(arena.FilledBytes == 0);
		for (int i < 200)
			arena.Copy(scope $"text number {i}");
		Test.Assert(arena.ReservedBytes == reserved);
		// An allocation larger than any chunk gets its own
		char8* large = arena.Alloc(1 << 21);
		large[(1 << 21) - 1] = 'x';
		Test.Assert(arena.ReservedBytes >= reserved + (1 << 21));
		// An empty copy still has a pointer
		Test.Assert(arena.Copy("").Ptr != null);
		arena.Release();
		Test.Assert(arena.ReservedBytes == 0 && arena.FilledBytes == 0);
		Test.Assert(arena.Copy("again") == "again");
	}

	[Test]
	public static void KeptSource_OwnsOnlyWhatIsOutside()
	{
		let arena = scope TextArena();
		let source = arena.Copy("name = \"value\"");
		var kept = KeptSource();
		kept.Set(source);
		StringView inside = source.Substring(8, 5);
		Test.Assert(kept.Contains(inside) && kept.Own(inside, arena).Ptr == inside.Ptr && kept.OffsetOf(inside) == 8);
		let outside = scope String("decoded");
		let owned = kept.Own(outside, arena);
		Test.Assert(owned == "decoded" && owned.Ptr != outside.Ptr && !kept.Contains(outside));
		kept.Clear();
		Test.Assert(!kept.IsSet && !kept.Contains(inside));
	}
}
