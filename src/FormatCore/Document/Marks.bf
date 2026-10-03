using System;
using internal FormatCore;

namespace FormatCore;

/// A PreserveStyle record's change marks, as bits of the format's own flags enum (Beef enums cannot be
/// extended, so each sibling keeps its enum and its records implement this over it).
internal interface IMarkedStyle
{
	/// Whether every bit of `bits` is set.
	bool HasMarks(uint32 bits);
	/// Sets the bits.
	void AddMarks(uint32 bits) mut;
}

/// Change marks for preserving writers that copy unchanged subtrees as one range (XmlBeef's MarkNode and
/// MarkChanged, JsonBeef's Mark): a change marks its node, and its ancestors get the format's
/// "changed below" bit up to the first one that already has it (its ancestors were marked with it).
internal static class Marks<TRecord, TStyle, TZeroIsNode>
	where TRecord : struct, ITreeRecord where TStyle : struct, IMarkedStyle where TZeroIsNode : const bool
{
	/// @brief Mark `bits` on `id` and `subtreeBit` on its ancestors.
	/// @param nodes The node table.
	/// @param styles The style table (grows to reach the nodes).
	/// @param id The changed node.
	/// @param bits What changed in it.
	/// @param subtreeBit The format's "changed below" bit.
	public static void MarkUp(TRecord* nodes, SideTable<TStyle> styles, uint32 id, uint32 bits, uint32 subtreeBit)
	{
		styles.At(id).AddMarks(bits);
		if (id == 0)
			return;
		uint32 parent = nodes[id].Parent;
		if (parent != 0 || TZeroIsNode)
			MarkChanged(nodes, styles, parent, subtreeBit);
	}

	/// @brief Mark `subtreeBit` on `id` and its ancestors (a child added, removed or changed), stopping
	/// at the first that has it. With TZeroIsNode node 0 is marked last; otherwise 0 ends the walk.
	/// @param nodes The node table.
	/// @param styles The style table.
	/// @param id The node.
	/// @param subtreeBit The format's "changed below" bit.
	public static void MarkChanged(TRecord* nodes, SideTable<TStyle> styles, uint32 id, uint32 subtreeBit)
	{
		uint32 current = id;
		while (true)
		{
			if (current == 0 && !TZeroIsNode)
				return;
			ref TStyle style = ref styles.At(current);
			if (style.HasMarks(subtreeBit))
				return;
			style.AddMarks(subtreeBit);
			if (current == 0)
				return;
			current = nodes[current].Parent;
		}
	}
}
