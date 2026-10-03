using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore.Tests;

/// KdlBeef/XmlBeef's link shape.
struct LinkedTestRecord : ITreeRecord
{
	public uint32 mParent;
	public uint32 mFirstChild;
	public uint32 mLastChild;
	public uint32 mNext;
	public uint32 mPrev;
	public int32 mChildCount;
	public bool mRemoved;

	public uint32 Parent { [Inline] get => mParent; [Inline] set mut => mParent = value; }
	public uint32 FirstChild { [Inline] get => mFirstChild; [Inline] set mut => mFirstChild = value; }
	public uint32 LastChild { [Inline] get => mLastChild; [Inline] set mut => mLastChild = value; }
	public uint32 Next { [Inline] get => mNext; [Inline] set mut => mNext = value; }
	public uint32 Prev { [Inline] get => mPrev; [Inline] set mut => mPrev = value; }
	public int32 ChildCount { [Inline] get => mChildCount; [Inline] set mut => mChildCount = value; }
	public bool IsRemoved { [Inline] get => mRemoved; }

	[Inline]
	public void SetLastChildAndCount(uint32 last, int32 count) mut
	{
		mLastChild = last;
		mChildCount = count;
	}

	[Inline]
	public void MarkRemoved() mut
	{
		mRemoved = true;
	}
}

/// JsonBeef's shape: last child and count packed in one word.
struct PackedTestRecord : ITreeRecord
{
	public uint64 mPayload;
	public uint32 mParent;
	public uint32 mFirstChild;
	public uint32 mNext;
	public uint32 mPrev;
	public uint8 mFlags;

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
	public bool IsRemoved { [Inline] get => (mFlags & 1) != 0; }

	[Inline]
	public void SetLastChildAndCount(uint32 last, int32 count) mut
	{
		mPayload = ((uint64)(uint32)count << 32) | last;
	}

	[Inline]
	public void MarkRemoved() mut
	{
		mFlags |= 1;
	}
}

struct TestStyle : IMarkedStyle
{
	public uint32 mFlags;

	[Inline]
	public bool HasMarks(uint32 bits) => (mFlags & bits) == bits;

	[Inline]
	public void AddMarks(uint32 bits) mut
	{
		mFlags |= bits;
	}
}

static class TreeTests
{
	/// The naive model: a parent and a child list per node; -1 parent: detached; removed nodes are gone.
	class Model
	{
		public List<int> mParent = new .() ~ delete _;
		public List<List<uint32>> mChildren = new .() ~ DeleteContainerAndItems!(_);
		public List<bool> mRemoved = new .() ~ delete _;

		public uint32 Add()
		{
			mParent.Add(-1);
			mChildren.Add(new .());
			mRemoved.Add(false);
			return (uint32)(mParent.Count - 1);
		}

		public void Detach(uint32 id)
		{
			int parent = mParent[id];
			mChildren[parent].Remove(id);
			mParent[id] = -1;
		}

		public void Preorder(uint32 id, List<uint32> order)
		{
			order.Add(id);
			for (let child in mChildren[id])
				Preorder(child, order);
		}

		public void Walk(uint32 id, List<(uint32, bool)> steps)
		{
			steps.Add((id, false));
			for (let child in mChildren[id])
				Walk(child, steps);
			steps.Add((id, true));
		}

		public bool IsAncestorOrSelf(uint32 ancestor, uint32 id)
		{
			int current = id;
			while (current >= 0)
			{
				if (current == ancestor)
					return true;
				current = mParent[current];
			}
			return false;
		}

		public void MarkRemoved(uint32 id)
		{
			mRemoved[id] = true;
			for (let child in mChildren[id])
				MarkRemoved(child);
		}
	}

	static void Check<TRecord>(List<TRecord> nodes, Model model, uint32 root, bool zeroIsNode)
		where TRecord : struct, ITreeRecord
	{
		TRecord* p = nodes.Ptr;
		for (int i < model.mParent.Count)
		{
			if (i == 0 && !zeroIsNode)
				continue;
			Test.Assert(p[i].IsRemoved == model.mRemoved[i]);
			if (model.mRemoved[i])
				continue;
			// Children forward and backward, count and parent links
			let children = model.mChildren[i];
			Test.Assert(p[i].ChildCount == children.Count);
			uint32 child = p[i].FirstChild;
			for (let expected in children)
			{
				Test.Assert(child == expected && p[child].Parent == (uint32)i);
				child = p[child].Next;
			}
			Test.Assert(child == 0);
			child = p[i].LastChild;
			for (int k = children.Count - 1; k >= 0; k--)
			{
				Test.Assert(child == children[k]);
				child = p[child].Prev;
			}
			Test.Assert(child == 0);
			if (model.mParent[i] < 0 && i != root)
				Test.Assert(p[i].Parent == 0 && p[i].Next == 0 && p[i].Prev == 0);
		}
		// Preorder three ways
		let expected = scope List<uint32>();
		model.Preorder(root, expected);
		let order = scope List<uint32>();
		Tree<TRecord, const true>.LiveOrder(p, root, order);
		Test.Assert(order.Count == expected.Count);
		for (int i < order.Count)
			Test.Assert(order[i] == expected[i]);
		let steps = scope List<(uint32, bool)>();
		model.Walk(root, steps);
		var walk = PreorderWalk<TRecord>(root);
		int at = 0;
		while (walk.Next(p, let id, let leaving))
		{
			Test.Assert(at < steps.Count && steps[at].0 == id && steps[at].1 == leaving);
			at++;
		}
		Test.Assert(at == steps.Count);
	}

	static void RandomOperations<TRecord, TZero>(int seed) where TRecord : struct, ITreeRecord where TZero : const bool
	{
		let random = scope Random(seed);
		let nodes = scope List<TRecord>();
		let model = scope Model();
		// Slot 0: the root (a real node), or unused with the root at 1
		nodes.Add(default);
		model.Add();
		uint32 root = 0;
		if (!TZero)
		{
			nodes.Add(default);
			root = model.Add();
		}
		model.mParent[root] = -1;
		let detached = scope List<uint32>();
		for (int step < 600)
		{
			TRecord* p = nodes.Ptr;
			int op = random.Next(10);
			// A live node in the tree to act on
			let live = scope List<uint32>();
			model.Preorder(root, live);
			uint32 target = live[random.Next(live.Count)];
			if (op <= 3 || detached.IsEmpty)
			{
				// New node, last child of a node in the tree
				nodes.Add(default);
				p = nodes.Ptr;
				uint32 id = model.Add();
				if (random.Next(2) == 0)
					Tree<TRecord, TZero>.LinkLastFresh(p, target, id);
				else
					Tree<TRecord, TZero>.LinkLast(p, target, id);
				model.mParent[id] = target;
				model.mChildren[target].Add(id);
			}
			else if (op <= 6)
			{
				// Relink a detached subtree before or after a non-root node, or last under one
				int pick = random.Next(detached.Count);
				uint32 id = detached[pick];
				detached.RemoveAt(pick);
				if (target != root && random.Next(3) != 0)
				{
					uint32 parent = (uint32)model.mParent[target];
					int index = model.mChildren[parent].IndexOf(target);
					if (random.Next(2) == 0)
					{
						Tree<TRecord, TZero>.LinkBefore(p, target, id);
						model.mChildren[parent].Insert(index, id);
					}
					else
					{
						Tree<TRecord, TZero>.LinkAfter(p, target, id);
						model.mChildren[parent].Insert(index + 1, id);
					}
					model.mParent[id] = parent;
				}
				else
				{
					Tree<TRecord, TZero>.LinkLast(p, target, id);
					model.mParent[id] = target;
					model.mChildren[target].Add(id);
				}
			}
			else if (op <= 8 && target != root)
			{
				// Unlink (a move later), checking IsSelfOrAncestor on the way
				uint32 other = live[random.Next(live.Count)];
				Test.Assert(Tree<TRecord, TZero>.IsSelfOrAncestor(p, target, other) == model.IsAncestorOrSelf(target, other));
				Tree<TRecord, TZero>.Unlink(p, target);
				model.Detach(target);
				detached.Add(target);
			}
			else if (target != root)
			{
				Tree<TRecord, TZero>.RemoveSubtree(p, target);
				model.Detach(target);
				model.MarkRemoved(target);
			}
			Check<TRecord>(nodes, model, root, TZero);
		}
		if (TZero)
			Test.Assert(Tree<TRecord, TZero>.IsSelfOrAncestor(nodes.Ptr, 0, (uint32)nodes.Count - 1));
	}

	[Test]
	public static void Tree_MatchesTheModel()
	{
		for (int seed < 6)
		{
			RandomOperations<LinkedTestRecord, const true>(seed);
			RandomOperations<LinkedTestRecord, const false>(seed + 100);
			RandomOperations<PackedTestRecord, const false>(seed + 200);
			RandomOperations<PackedTestRecord, const true>(seed + 300);
		}
	}

	[Test]
	public static void Tree_NextPreorderSkipsChildrenWhenAsked()
	{
		let nodes = scope List<LinkedTestRecord>();
		for (int i < 6)
			nodes.Add(default);
		LinkedTestRecord* p = nodes.Ptr;
		// 1 { 2 { 3 } 4 } 5 under 0
		Tree<LinkedTestRecord, const true>.LinkLast(p, 0, 1);
		Tree<LinkedTestRecord, const true>.LinkLast(p, 1, 2);
		Tree<LinkedTestRecord, const true>.LinkLast(p, 2, 3);
		Tree<LinkedTestRecord, const true>.LinkLast(p, 1, 4);
		Tree<LinkedTestRecord, const true>.LinkLast(p, 0, 5);
		Test.Assert(Tree<LinkedTestRecord, const true>.NextPreorder(p, 0, 2, false) == 4);
		Test.Assert(Tree<LinkedTestRecord, const true>.NextPreorder(p, 0, 2, true) == 3);
		Test.Assert(Tree<LinkedTestRecord, const true>.NextPreorder(p, 1, 4, true) == 0);
		Test.Assert(Tree<LinkedTestRecord, const true>.NextPreorder(p, 0, 4, true) == 5);
		Test.Assert(!Tree<LinkedTestRecord, const false>.IsSelfOrAncestor(p, 0, 3));
		Test.Assert(Tree<LinkedTestRecord, const true>.IsSelfOrAncestor(p, 0, 3));
		Test.Assert(Tree<LinkedTestRecord, const true>.IsSelfOrAncestor(p, 1, 3) && !Tree<LinkedTestRecord, const true>.IsSelfOrAncestor(p, 4, 3));
	}

	[Test]
	public static void Marks_PropagateToTheFirstMarkedAncestor()
	{
		const uint32 valueDirty = 1;
		const uint32 subtreeDirty = 2;
		let nodes = scope List<LinkedTestRecord>();
		for (int i < 5)
			nodes.Add(default);
		LinkedTestRecord* p = nodes.Ptr;
		// 0 { 1 { 2 { 3 } } 4 }
		Tree<LinkedTestRecord, const true>.LinkLast(p, 0, 1);
		Tree<LinkedTestRecord, const true>.LinkLast(p, 1, 2);
		Tree<LinkedTestRecord, const true>.LinkLast(p, 2, 3);
		Tree<LinkedTestRecord, const true>.LinkLast(p, 0, 4);
		let styles = scope SideTable<TestStyle>();
		Marks<LinkedTestRecord, TestStyle, const true>.MarkUp(p, styles, 3, valueDirty, subtreeDirty);
		Test.Assert(styles.Get(3).mFlags == valueDirty);
		Test.Assert(styles.Get(2).mFlags == subtreeDirty && styles.Get(1).mFlags == subtreeDirty && styles.Get(0).mFlags == subtreeDirty);
		Test.Assert(styles.Get(4).mFlags == 0);
		// An ancestor already marked stops the walk: clear 0's mark, mark below 2 again
		styles.At(0).mFlags = 0;
		Marks<LinkedTestRecord, TestStyle, const true>.MarkUp(p, styles, 3, valueDirty, subtreeDirty);
		Test.Assert(styles.Get(0).mFlags == 0);
		// Without a node 0 the walk ends below it
		let jsonStyles = scope SideTable<TestStyle>();
		Marks<LinkedTestRecord, TestStyle, const false>.MarkUp(p, jsonStyles, 3, valueDirty, subtreeDirty);
		Test.Assert(jsonStyles.Get(1).mFlags == subtreeDirty && jsonStyles.Get(0).mFlags == 0);
		Marks<LinkedTestRecord, TestStyle, const false>.MarkChanged(p, jsonStyles, 4, subtreeDirty);
		Test.Assert(jsonStyles.Get(4).mFlags == subtreeDirty && jsonStyles.Get(0).mFlags == 0);
	}
}
