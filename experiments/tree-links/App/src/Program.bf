using System;
using Core;

namespace App;

/// KdlBeef/XmlBeef's shape: five links and a count, plus payload (72 bytes).
struct LinkedRecord : ITreeRecord
{
	public uint32 mParent;
	public uint32 mFirstChild;
	public uint32 mLastChild;
	public uint32 mNext;
	public uint32 mPrev;
	public int32 mChildCount;
	public uint64[6] mPayload;

	public uint32 Parent { [Inline] get => mParent; [Inline] set mut => mParent = value; }
	public uint32 FirstChild { [Inline] get => mFirstChild; [Inline] set mut => mFirstChild = value; }
	public uint32 LastChild { [Inline] get => mLastChild; [Inline] set mut => mLastChild = value; }
	public uint32 Next { [Inline] get => mNext; [Inline] set mut => mNext = value; }
	public uint32 Prev { [Inline] get => mPrev; [Inline] set mut => mPrev = value; }
	public int32 ChildCount { [Inline] get => mChildCount; [Inline] set mut => mChildCount = value; }

	[Inline]
	public void SetLastChildAndCount(uint32 last, int32 count) mut
	{
		mLastChild = last;
		mChildCount = count;
	}
}

/// JsonBeef's shape: the last child and the count packed into the payload (40 bytes).
struct PackedRecord : ITreeRecord
{
	public uint64 mPayload;
	public uint64 mName;
	public uint32 mParent;
	public uint32 mFirstChild;
	public uint32 mNext;
	public uint32 mPrev;
	public uint64 mKind;

	public uint32 Parent { [Inline] get => mParent; [Inline] set mut => mParent = value; }
	public uint32 FirstChild { [Inline] get => mFirstChild; [Inline] set mut => mFirstChild = value; }
	public uint32 LastChild
	{
		[Inline] get => (uint32)mPayload;
		[Inline] set mut => mPayload = (mPayload & 0xFFFFFFFF00000000UL) | value;
	}
	public uint32 Next { [Inline] get => mNext; [Inline] set mut => mNext = value; }
	public uint32 Prev { [Inline] get => mPrev; [Inline] set mut => mPrev = value; }
	public int32 ChildCount
	{
		[Inline] get => (int32)(mPayload >> 32);
		[Inline] set mut => mPayload = (mPayload & 0xFFFFFFFFUL) | ((uint64)(uint32)value << 32);
	}

	[Inline]
	public void SetLastChildAndCount(uint32 last, int32 count) mut
	{
		mPayload = ((uint64)(uint32)count << 32) | last;
	}
}

class Program
{
	const int N = 1 << 20;
	static uint32[] sParents;

	static void MakeParents()
	{
		sParents = new uint32[N];
		uint64 h = 12345;
		for (int i = 1; i < N; i++)
		{
			h = h * 6364136223846793005UL + 1442695040888963407UL;
			uint32 r = (uint32)(h >> 33);
			sParents[i] = (r % 4 == 0) ? r % (uint32)i : (uint32)Math.Max(0, i - 1 - (int)(r % 4));
		}
	}

	// The App's own code on the fields (the sibling today)

	[NoInline]
	static void BuildDirect(LinkedRecord* nodes)
	{
		Internal.MemSet(nodes, 0, N * sizeof(LinkedRecord));
		for (uint32 child = 1; child < N; child++)
		{
			uint32 parent = sParents[child];
			ref LinkedRecord p = ref nodes[parent];
			ref LinkedRecord c = ref nodes[child];
			c.mParent = parent;
			c.mNext = 0;
			c.mPrev = p.mLastChild;
			if (p.mLastChild != 0)
				nodes[p.mLastChild].mNext = child;
			else
				p.mFirstChild = child;
			p.mLastChild = child;
			p.mChildCount++;
		}
	}

	[NoInline]
	static void BuildTree(LinkedRecord* nodes)
	{
		Internal.MemSet(nodes, 0, N * sizeof(LinkedRecord));
		for (uint32 child = 1; child < N; child++)
			Tree<LinkedRecord>.LinkLast(nodes, sParents[child], child);
	}

	[NoInline]
	static void BuildPackedDirect(PackedRecord* nodes)
	{
		Internal.MemSet(nodes, 0, N * sizeof(PackedRecord));
		for (uint32 child = 1; child < N; child++)
		{
			uint32 parent = sParents[child];
			ref PackedRecord container = ref nodes[parent];
			uint32 last = (uint32)container.mPayload;
			nodes[child].mParent = parent;
			if (last == 0)
				container.mFirstChild = child;
			else
			{
				nodes[last].mNext = child;
				nodes[child].mPrev = last;
			}
			container.mPayload = ((uint64)(uint32)((int)(container.mPayload >> 32) + 1) << 32) | child;
		}
	}

	[NoInline]
	static void BuildPackedTree(PackedRecord* nodes)
	{
		Internal.MemSet(nodes, 0, N * sizeof(PackedRecord));
		for (uint32 child = 1; child < N; child++)
			Tree<PackedRecord>.LinkLastFresh(nodes, sParents[child], child);
	}

	[NoInline]
	static uint64 WalkDirect(LinkedRecord* nodes)
	{
		uint64 sum = 0;
		uint32 id = 0;
		while (true)
		{
			sum += id;
			uint32 first = nodes[id].mFirstChild;
			if (first != 0)
			{
				id = first;
				continue;
			}
			uint32 current = id;
			id = 0;
			while (current != 0)
			{
				uint32 next = nodes[current].mNext;
				if (next != 0)
				{
					id = next;
					break;
				}
				current = nodes[current].mParent;
			}
			if (id == 0)
				return sum;
		}
	}

	[NoInline]
	static uint64 WalkTree<TRecord>(TRecord* nodes) where TRecord : struct, ITreeRecord
	{
		uint64 sum = 0;
		uint32 id = 0;
		while (true)
		{
			sum += id;
			id = Tree<TRecord>.NextPreorder(nodes, 0, id);
			if (id == 0)
				return sum;
		}
	}

	[NoInline]
	static uint64 WalkPackedDirect(PackedRecord* nodes)
	{
		uint64 sum = 0;
		uint32 id = 0;
		while (true)
		{
			sum += id;
			uint32 first = nodes[id].mFirstChild;
			if (first != 0)
			{
				id = first;
				continue;
			}
			uint32 current = id;
			id = 0;
			while (current != 0)
			{
				uint32 next = nodes[current].mNext;
				if (next != 0)
				{
					id = next;
					break;
				}
				current = nodes[current].mParent;
			}
			if (id == 0)
				return sum;
		}
	}

	public static int Main(String[] args)
	{
		if (args.Count < 2)
		{
			Console.WriteLine("Usage: App <mode> <passes>");
			return 1;
		}
		StringView mode = args[0];
		int passes = int.Parse(args[1]).GetValueOrDefault();
		MakeParents();
		defer delete sParents;
		let linked = new LinkedRecord[N];
		defer delete linked;
		let packed = new PackedRecord[N];
		defer delete packed;
		uint64 check = 0;
		if (mode.StartsWith("walk"))
		{
			BuildDirect(linked.Ptr);
			BuildPackedDirect(packed.Ptr);
		}
		for (int pass < passes)
		{
			switch (mode)
			{
			case "build-direct": BuildDirect(linked.Ptr); check += linked[N - 1].mParent;
			case "build-tree": BuildTree(linked.Ptr); check += linked[N - 1].mParent;
			case "build-packed-direct": BuildPackedDirect(packed.Ptr); check += packed[N - 1].mParent;
			case "build-packed-tree": BuildPackedTree(packed.Ptr); check += packed[N - 1].mParent;
			case "walk-direct": check += WalkDirect(linked.Ptr);
			case "walk-tree": check += WalkTree(linked.Ptr);
			case "walk-packed-direct": check += WalkPackedDirect(packed.Ptr);
			case "walk-packed-tree": check += WalkTree(packed.Ptr);
			default:
				Console.WriteLine("unknown mode");
				return 1;
			}
		}
		// The builds must agree: the same links either way
		if (mode == "build-tree" || mode == "build-packed-tree")
		{
			let other = new LinkedRecord[N];
			defer delete other;
			BuildDirect(other.Ptr);
			BuildTree(linked.Ptr);
			for (int i < N)
			{
				if (other[i].mFirstChild != linked[i].mFirstChild || other[i].mLastChild != linked[i].mLastChild ||
					other[i].mNext != linked[i].mNext || other[i].mPrev != linked[i].mPrev || other[i].mChildCount != linked[i].mChildCount)
				{
					Console.WriteLine("MISMATCH");
					return 2;
				}
			}
		}
		Console.WriteLine(check);
		return 0;
	}
}
