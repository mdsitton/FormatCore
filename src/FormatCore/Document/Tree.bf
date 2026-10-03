using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore;

/// What a node record exposes to the tree algorithms. Each format keeps its own record layout
/// (KdlNodeRecord, XmlNodeRecord, the packed JsonNodeRecord) and implements these as `[Inline]`
/// accessors over its fields; `experiments/tree-links` measured them as free in Release (the same
/// instructions per node as code on the fields) for both a five-link record and a packed one.
/// Links are node IDs; 0 means none (slot 0 is never a child or a sibling).
internal interface ITreeRecord
{
	uint32 Parent { get; set mut; }
	uint32 FirstChild { get; set mut; }
	uint32 LastChild { get; set mut; }
	uint32 Next { get; set mut; }
	uint32 Prev { get; set mut; }
	int32 ChildCount { get; set mut; }
	/// Set both at once (one store when they share a word, as JsonBeef's payload does).
	void SetLastChildAndCount(uint32 last, int32 count) mut;
	/// Whether the node was removed (its slot is kept until the document is cleared or compacted).
	bool IsRemoved { get; }
	void MarkRemoved() mut;
}

/// Link operations on a node table (KdlBeef's and XmlBeef's identical LinkLastChild, LinkBefore,
/// LinkAfter, Unlink, RemoveNode and IsSelfOrAncestor; JsonBeef's AppendChild and Unlink). `TZeroIsNode`
/// says whether slot 0 is a real node that is everyone's ancestor (XmlBeef's document node, KdlBeef's
/// hidden root) or unused (JsonBeef, whose root is 1). Children form a doubly linked list.
internal static class Tree<TRecord, TZeroIsNode> where TRecord : struct, ITreeRecord where TZeroIsNode : const bool
{
	/// @brief Link the unlinked node `child` as the last child of `parent`.
	/// @param nodes The node table.
	/// @param parent The parent.
	/// @param child The child.
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

	/// @brief LinkLast for a child whose links are all 0 (a builder's new, zeroed record): two stores
	/// fewer (JsonBeef's AppendChild).
	/// @param nodes The node table.
	/// @param parent The parent.
	/// @param child The child.
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

	/// @brief Link the unlinked node `child` before `sibling`, under the sibling's parent.
	/// @param nodes The node table.
	/// @param sibling The linked node to precede.
	/// @param child The child.
	public static void LinkBefore(TRecord* nodes, uint32 sibling, uint32 child)
	{
		ref TRecord s = ref nodes[sibling];
		ref TRecord c = ref nodes[child];
		uint32 parent = s.Parent;
		ref TRecord p = ref nodes[parent];
		c.Parent = parent;
		c.Next = sibling;
		uint32 prev = s.Prev;
		c.Prev = prev;
		if (prev != 0)
			nodes[prev].Next = child;
		else
			p.FirstChild = child;
		s.Prev = child;
		p.ChildCount = p.ChildCount + 1;
	}

	/// @brief Link the unlinked node `child` after `sibling`, under the sibling's parent.
	/// @param nodes The node table.
	/// @param sibling The linked node to follow.
	/// @param child The child.
	public static void LinkAfter(TRecord* nodes, uint32 sibling, uint32 child)
	{
		uint32 next = nodes[sibling].Next;
		if (next != 0)
			LinkBefore(nodes, next, child);
		else
			LinkLast(nodes, nodes[sibling].Parent, child);
	}

	/// @brief Take `id` (and its subtree) out of its parent's children; it stays in the table with no
	/// parent (0) and no siblings.
	/// @param nodes The node table.
	/// @param id The node.
	public static void Unlink(TRecord* nodes, uint32 id)
	{
		ref TRecord c = ref nodes[id];
		ref TRecord p = ref nodes[c.Parent];
		uint32 prev = c.Prev;
		uint32 next = c.Next;
		uint32 last = p.LastChild;
		if (prev != 0)
			nodes[prev].Next = next;
		else
			p.FirstChild = next;
		if (next != 0)
			nodes[next].Prev = prev;
		else
			last = prev;
		p.SetLastChildAndCount(last, p.ChildCount - 1);
		c.Parent = 0;
		c.Next = 0;
		c.Prev = 0;
	}

	/// @brief Unlink `id` and mark it and every descendant removed (their slots are not reused before
	/// the document is cleared, so handles to them become invalid rather than naming other nodes).
	/// @param nodes The node table.
	/// @param id The subtree's root.
	public static void RemoveSubtree(TRecord* nodes, uint32 id)
	{
		Unlink(nodes, id);
		MarkRemovedSubtree(nodes, id);
	}

	/// @brief Mark `top` and every descendant removed, through the links (no recursion).
	/// @param nodes The node table.
	/// @param top The subtree's root.
	public static void MarkRemovedSubtree(TRecord* nodes, uint32 top)
	{
		uint32 current = top;
		while (current != 0)
		{
			nodes[current].MarkRemoved();
			current = NextPreorder(nodes, top, current, true);
		}
	}

	/// @brief Whether `ancestor` is `id` or one of its ancestors (a move into its own subtree is
	/// refused with this). With TZeroIsNode, node 0 is everyone's ancestor.
	/// @param nodes The node table.
	/// @param ancestor The candidate ancestor.
	/// @param id The node.
	/// @return Whether it is.
	public static bool IsSelfOrAncestor(TRecord* nodes, uint32 ancestor, uint32 id)
	{
		if (TZeroIsNode && ancestor == 0)
			return true;
		uint32 current = id;
		while (current != 0)
		{
			if (current == ancestor)
				return true;
			current = nodes[current].Parent;
		}
		return false;
	}

	/// @brief The node after `id` in preorder within `root`'s subtree, or 0 at its end. With `enter`
	/// false, `id`'s children are skipped.
	/// @param nodes The node table.
	/// @param root The subtree's root.
	/// @param id The current node (in the subtree).
	/// @param enter Whether to visit `id`'s children.
	/// @return The next node, or 0.
	[Inline]
	public static uint32 NextPreorder(TRecord* nodes, uint32 root, uint32 id, bool enter = true)
	{
		if (enter)
		{
			uint32 first = nodes[id].FirstChild;
			if (first != 0)
				return first;
		}
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

	/// @brief The live nodes of `root`'s subtree in preorder (`root` first): the new order for a
	/// compaction.
	/// @param nodes The node table.
	/// @param root The subtree's root.
	/// @param order Receives the IDs (appended).
	public static void LiveOrder(TRecord* nodes, uint32 root, List<uint32> order)
	{
		uint32 current = root;
		while (true)
		{
			order.Add(current);
			current = NextPreorder(nodes, root, current, true);
			if (current == 0)
				return;
		}
	}
}

/// A preorder walk with enter and leave steps, for writers that close what they open (end tags, `}`)
/// without recursion: every node of the subtree is returned twice, entering (`leaving` false) and,
/// after its descendants, leaving; the root first and last.
internal struct PreorderWalk<TRecord> where TRecord : struct, ITreeRecord
{
	uint32 mRoot;
	uint32 mCurrent;
	bool mLeaving;
	bool mStarted;
	bool mDone;

	/// @brief A walk of `root`'s subtree.
	/// @param root The subtree's root.
	public this(uint32 root)
	{
		mRoot = root;
		mCurrent = root;
		mLeaving = false;
		mStarted = false;
		mDone = false;
	}

	/// @brief The next step.
	/// @param nodes The node table.
	/// @param id Receives the node.
	/// @param leaving Receives whether the step leaves it (its children, if any, are done).
	/// @return False when the walk is over.
	public bool Next(TRecord* nodes, out uint32 id, out bool leaving) mut
	{
		id = 0;
		leaving = false;
		if (mDone)
			return false;
		if (!mStarted)
		{
			mStarted = true;
			id = mCurrent;
			return true;
		}
		if (!mLeaving)
		{
			uint32 first = nodes[mCurrent].FirstChild;
			if (first != 0)
			{
				mCurrent = first;
				id = first;
				return true;
			}
			// No children: leave it now
			mLeaving = true;
			id = mCurrent;
			leaving = true;
			if (mCurrent == mRoot)
				mDone = true;
			return true;
		}
		// Left mCurrent: its next sibling is entered, or its parent left
		uint32 next = nodes[mCurrent].Next;
		if (next != 0)
		{
			mCurrent = next;
			mLeaving = false;
			id = next;
			return true;
		}
		mCurrent = nodes[mCurrent].Parent;
		id = mCurrent;
		leaving = true;
		if (mCurrent == mRoot)
			mDone = true;
		return true;
	}
}
