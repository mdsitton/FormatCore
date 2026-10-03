using System;

namespace Core;

/// What a node record exposes to the link algorithms (the candidate for FormatCore's ITreeRecord).
public interface ITreeRecord
{
	uint32 Parent { get; set mut; }
	uint32 FirstChild { get; set mut; }
	uint32 LastChild { get; set mut; }
	uint32 Next { get; set mut; }
	uint32 Prev { get; set mut; }
	int32 ChildCount { get; set mut; }
	/// Both at once (one store for a packed record).
	void SetLastChildAndCount(uint32 last, int32 count) mut;
}

/// The link algorithms over a table of records, through the accessors.
public static class Tree<TRecord> where TRecord : struct, ITreeRecord
{
	[Inline]
	public static void LinkLast(TRecord* nodes, uint32 parent, uint32 child)
	{
		ref TRecord p = ref nodes[parent];
		ref TRecord c = ref nodes[child];
		c.Parent = parent;
		c.Next = 0;
		uint32 last = p.LastChild;
		c.Prev = last;
		if (last != 0)
			nodes[last].Next = child;
		else
			p.FirstChild = child;
		p.SetLastChildAndCount(child, p.ChildCount + 1);
	}

	/// LinkLast for a child whose links are all 0 (a builder's new node): JsonBeef's AppendChild.
	[Inline]
	public static void LinkLastFresh(TRecord* nodes, uint32 parent, uint32 child)
	{
		ref TRecord p = ref nodes[parent];
		uint32 last = p.LastChild;
		nodes[child].Parent = parent;
		if (last == 0)
			p.FirstChild = child;
		else
		{
			nodes[last].Next = child;
			nodes[child].Prev = last;
		}
		p.SetLastChildAndCount(child, p.ChildCount + 1);
	}

	/// The node after `id` in preorder within `root`'s subtree, or 0 at its end.
	[Inline]
	public static uint32 NextPreorder(TRecord* nodes, uint32 root, uint32 id)
	{
		uint32 first = nodes[id].FirstChild;
		if (first != 0)
			return first;
		uint32 current = id;
		while (current != root)
		{
			uint32 next = nodes[current].Next;
			if (next != 0)
				return next;
			current = nodes[current].Parent;
		}
		return 0;
	}
}
