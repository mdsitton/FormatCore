using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore.Tests;

/// TomlTableSlot's shape: a key and a value.
struct TestSlot : IKeyedSlot
{
	public StringView mKey;
	public int mValue;

	public StringView Key { [Inline] get => mKey; [Inline] set mut => mKey = value; }
}

/// Keys of an index test: ID to key through a list.
struct ListKeys : IKeySource
{
	public List<StringView> mKeys;

	public StringView KeyOf(uint32 id) => mKeys[id];
}

static class IndexTests
{
	static void MakeKeys(int count, TextArena arena, List<StringView> keys)
	{
		for (int i < count)
			keys.Add(arena.Copy(scope $"key-{i}-{i * 7919 % 1000}"));
	}

	/// Keys whose hash under `seed` falls in slot 0 of a 64-slot table: what an attacker who knew an
	/// unseeded hash would send.
	static void CollidingKeys(uint64 seed, TextArena arena, List<StringView> keys)
	{
		let candidate = scope String();
		for (int i < 20000)
		{
			candidate.Clear();
			candidate.AppendF("k{}", i);
			if ((ByteHash.Hash(candidate, seed) & 63) == 0)
				keys.Add(arena.Copy(candidate));
		}
	}

	[Test]
	public static void ByteHash_IsSeededPerTable()
	{
		// Seeds differ per call, and a key hashes differently under two of them
		uint64 a = ByteHash.NewSeed();
		uint64 b = ByteHash.NewSeed();
		Test.Assert(a != b && a != 0 && b != 0);
		int same = 0;
		for (int i < 100)
		{
			let key = scope $"name{i}";
			if (ByteHash.Hash(key, a) == ByteHash.Hash(key, b))
				same++;
		}
		Test.Assert(same <= 1);
		// Bytes past the length are never read: the hash of a prefix ignores what follows it
		char8[32] buffer = ?;
		for (int length <= 16)
		{
			for (int i < 32)
				buffer[i] = (char8)('a' + i);
			uint32 before = ByteHash.Hash(&buffer, length, a);
			for (int i = length; i < 32; i++)
				buffer[i] = '#';
			Test.Assert(ByteHash.Hash(&buffer, length, a) == before);
		}
		// Keys crafted to collide under one seed spread under another: about 300 keys fill all 64
		// buckets (XmlNameTable's hash, whose 4-7 byte words overlapped, left them in 34-51)
		let arena = scope TextArena();
		let colliding = scope List<StringView>();
		CollidingKeys(a, arena, colliding);
		Test.Assert(colliding.Count >= 200 && colliding.Count <= 450);
		let buckets = scope HashSet<uint32>();
		for (let key in colliding)
			buckets.Add(ByteHash.Hash(key, b) & 63);
		Test.Assert(buckets.Count >= 56);
	}

	[Test]
	public static void ByteHash_UsesEveryByte()
	{
		// Keys of each length that differ only in their first and last bytes hash apart
		uint64 seed = ByteHash.NewSeed();
		let hashes = scope HashSet<uint32>();
		let key = scope String();
		for (int length = 1; length <= 12; length++)
		{
			hashes.Clear();
			for (char8 first = 'a'; first <= 'z'; first++)
			{
				for (char8 last = 'a'; last <= 'z'; last++)
				{
					key.Clear();
					key.Append(first);
					for (int i = 1; i < length - 1; i++)
						key.Append('m');
					if (length > 1)
						key.Append(last);
					hashes.Add(ByteHash.Hash(key, seed));
				}
			}
			Test.Assert(hashes.Count == (length == 1 ? 26 : 26 * 26));
		}
	}

	[Test]
	public static void OpenIdIndex_FindsUnderForcedCollisions()
	{
		let arena = scope TextArena();
		let keys = scope List<StringView>();
		keys.Add("");
		uint64 seed = 0x01234567;
		CollidingKeys(seed, arena, keys);
		var index = OpenIdIndex(seed);
		defer index.Dispose();
		let source = ListKeys() { mKeys = keys };
		for (int id = 1; id < keys.Count; id++)
		{
			uint32 found = index.FindOrInsert(source, keys[id], index.HashOf(keys[id]), (uint32)id, let added);
			Test.Assert(added && found == (uint32)id);
			// Never more than half full
			Test.Assert(index.SlotCount >= index.Count * 2);
		}
		for (int id = 1; id < keys.Count; id++)
		{
			Test.Assert(index.Find(source, keys[id]) == (uint32)id);
			Test.Assert(index.FindOrInsert(source, keys[id], index.HashOf(keys[id]), 999, let added) == (uint32)id && !added);
		}
		Test.Assert(index.Find(source, "absent") == 0);
	}

	[Test]
	public static void OpenIdIndex_LastWinsAndRebuild()
	{
		let keys = scope List<StringView>();
		keys.Add("");
		keys.Add("a");
		keys.Add("b");
		keys.Add("a");
		keys.Add("c");
		let source = ListKeys() { mKeys = keys };
		OpenIdIndex index = default;
		defer index.Dispose();
		Test.Assert(index.Find(source, "a") == 0 && index.SlotCount == 0);
		for (uint32 id = 1; id < 5; id++)
			index.Set(source, keys[id], id);
		Test.Assert(index.Seed != 0);
		Test.Assert(index.Count == 3 && index.Find(source, "a") == 3 && index.Find(source, "b") == 2);
		// Rebuild after removing ID 3: the earlier "a" is found again
		uint32[?] remaining = .(1, 2, 4);
		index.Rebuild(source, remaining);
		Test.Assert(index.Count == 3 && index.Find(source, "a") == 1 && index.Find(source, "c") == 4);
		index.Clear();
		Test.Assert(index.Count == 0 && index.Find(source, "a") == 0);
	}

	[Test]
	public static void OrderedMap_MatchesAScanAcrossTheThreshold()
	{
		let arena = scope TextArena();
		let pool = scope List<StringView>();
		MakeKeys(64, arena, pool);
		var map = OrderedMap<TestSlot, const 8>();
		defer map.Dispose();
		let model = scope List<StringView>();
		let random = scope Random(11);
		for (int step < 3000)
		{
			int op = random.Next(10);
			if (op < 6)
			{
				StringView key = pool[random.Next(pool.Count)];
				int at = map.FindOrAdd(key, let added);
				int expected = model.IndexOf(key);
				if (expected < 0)
				{
					Test.Assert(added && at == model.Count);
					model.Add(key);
					map[at].mValue = at;
				}
				else
					Test.Assert(!added && at == expected);
			}
			else if (op < 8 && model.Count > 0)
			{
				int at = random.Next(model.Count);
				map.RemoveAt(at);
				model.RemoveAt(at);
			}
			else if (model.Count > 0)
			{
				// Rename to a key not in use
				StringView key = pool[random.Next(pool.Count)];
				if (model.IndexOf(key) < 0)
				{
					int at = random.Next(model.Count);
					map.SetKeyAt(at, key);
					model[at] = key;
				}
			}
			Test.Assert(map.Count == model.Count && map.IsIndexed == (model.Count > 8));
			for (let key in pool)
				Test.Assert(map.IndexOf(key) == model.IndexOf(key));
			for (int i < model.Count)
				Test.Assert(map[i].Key == model[i]);
		}
	}

	/// Bug 3 (TomlBeef's TomlEntryMap hashes unseeded): FormatCore's map seeds its index per map, so
	/// keys crafted to collide under one map's hash do not collide in another's.
	[Test]
	public static void OrderedMap_IndexIsSeededPerMap()
	{
		let arena = scope TextArena();
		let keys = scope List<StringView>();
		MakeKeys(20, arena, keys);
		var first = OrderedMap<TestSlot, const 8>();
		defer first.Dispose();
		var second = OrderedMap<TestSlot, const 8>();
		defer second.Dispose();
		for (let key in keys)
		{
			first.FindOrAdd(key, ?);
			second.FindOrAdd(key, ?);
		}
		Test.Assert(first.IsIndexed && second.IsIndexed);
		Test.Assert(first.IndexSeed != 0 && second.IndexSeed != 0 && first.IndexSeed != second.IndexSeed);

		// Keys that all collide under the first map's seed
		let colliding = scope List<StringView>();
		CollidingKeys(first.IndexSeed, arena, colliding);
		var victim = OrderedMap<TestSlot, const 8>();
		defer victim.Dispose();
		let buckets = scope HashSet<uint32>();
		for (let key in colliding)
		{
			victim.FindOrAdd(key, ?);
			buckets.Add(ByteHash.Hash(key, victim.IndexSeed) & 63);
		}
		Test.Assert(victim.IndexSeed != first.IndexSeed && buckets.Count >= 56);
		for (int i < colliding.Count)
			Test.Assert(victim.IndexOf(colliding[i]) == i);

		// A forced seed reproduces a collision attack; lookups stay correct, only slower
		var forced = OrderedMap<TestSlot, const 8>();
		defer forced.Dispose();
		forced.SetIndexSeed(first.IndexSeed);
		for (let key in colliding)
			forced.FindOrAdd(key, ?);
		Test.Assert(forced.IndexSeed == first.IndexSeed);
		for (int i < colliding.Count)
			Test.Assert(forced.IndexOf(colliding[i]) == i);
	}

	[Test]
	public static void InternTable_InternsAndKeepsPredefinedNames()
	{
		StringView[?] predefined = .("xml", "xmlns");
		let table = scope InternTable(predefined);
		Test.Assert(table.Count == 2 && table.Find("xml") == 1 && table.Find("xmlns") == 2 && table[1] == "xml");
		let ids = scope List<uint32>();
		let views = scope List<StringView>();
		for (int i < 500)
		{
			let name = scope $"name{i % 300}";
			uint32 id = ((i % 2) == 0) ? table.Intern(name) : table.InternCached(name);
			if (i < 300)
			{
				Test.Assert(id == (uint32)(i + 3));
				ids.Add(id);
				views.Add(table[id]);
			}
			else
				Test.Assert(id == ids[i % 300]);
		}
		// Text never moves while the table grows
		for (int i < 300)
		{
			Test.Assert(table[ids[i]].Ptr == views[i].Ptr && table[ids[i]] == scope $"name{i}");
			Test.Assert(table.FindCached(scope $"name{i}") == ids[i]);
		}
		Test.Assert(table.Find("absent") == 0 && table.FindCached("absent") == 0 && table.Find("") == 0);
		Test.Assert(table.Intern("") != 0);
		// Clear keeps the predefined names at their IDs; a stale cached ID is not trusted
		table.Clear();
		Test.Assert(table.Count == 2 && table.Find("xmlns") == 2 && table.Find("name5") == 0);
		Test.Assert(table.InternCached("name5") == 3 && table.InternCached("xml") == 1);
		table.Release();
		Test.Assert(table.Count == 2 && table.Find("xml") == 1 && table.Intern("again") == 3);
		// Each table has its own seed
		let other = scope InternTable();
		Test.Assert(other.Seed != table.Seed && other.Intern("x") == 1);
	}
}
