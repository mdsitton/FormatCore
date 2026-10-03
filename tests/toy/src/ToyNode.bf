using System;
using System.Collections;

namespace ToyFormat;

/// What a ToyNode holds.
public enum ToyKind
{
	Null,
	Bool,
	Integer,
	UInteger,
	Float,
	Text,
	List,
	Map
}

/// The toy format's value: a JSON-like tree (maps keep their keys in order; the last of two equal keys
/// wins on lookup).
public class ToyNode
{
	public ToyKind mKind;
	public bool mBool;
	public int64 mInteger;
	public uint64 mUInteger;
	public double mFloat;
	public String mText ~ delete _;
	public List<ToyNode> mItems ~ DeleteContainerAndItems!(_);
	public List<String> mKeys ~ DeleteContainerAndItems!(_);

	public this()
	{
	}

	/// Back to Null, dropping what it held.
	public void Reset()
	{
		mKind = .Null;
		DeleteAndNullify!(mText);
		if (mItems != null)
			ClearAndDeleteItems!(mItems);
		if (mKeys != null)
			ClearAndDeleteItems!(mKeys);
	}

	public void SetBool(bool value)
	{
		Reset();
		mKind = .Bool;
		mBool = value;
	}

	public void SetInteger(int64 value)
	{
		Reset();
		mKind = .Integer;
		mInteger = value;
	}

	public void SetUInteger(uint64 value)
	{
		Reset();
		mKind = .UInteger;
		mUInteger = value;
	}

	public void SetFloat(double value)
	{
		Reset();
		mKind = .Float;
		mFloat = value;
	}

	public void SetText(StringView value)
	{
		Reset();
		mKind = .Text;
		mText = new .(value);
	}

	public void MakeList()
	{
		if (mKind == .List)
			return;
		Reset();
		mKind = .List;
		if (mItems == null)
			mItems = new .();
	}

	public void MakeMap()
	{
		if (mKind == .Map)
			return;
		Reset();
		mKind = .Map;
		if (mItems == null)
			mItems = new .();
		if (mKeys == null)
			mKeys = new .();
	}

	/// A new item at the end of a list.
	public ToyNode Add()
	{
		MakeList();
		let node = new ToyNode();
		mItems.Add(node);
		return node;
	}

	/// The value of `key` in a map (the last of equal keys), or null.
	public ToyNode Get(StringView key)
	{
		if (mKind != .Map)
			return null;
		for (int i = mKeys.Count - 1; i >= 0; i--)
		{
			if (mKeys[i] == key)
				return mItems[i];
		}
		return null;
	}

	/// The value of `key` in a map, added (Null) if absent.
	public ToyNode Set(StringView key)
	{
		MakeMap();
		if (let existing = Get(key))
			return existing;
		mKeys.Add(new .(key));
		let node = new ToyNode();
		mItems.Add(node);
		return node;
	}

	/// Renames the member `from` to `to` (if there is one and `to` is absent).
	public void Rename(StringView from, StringView to)
	{
		if (mKind != .Map || Get(to) != null)
			return;
		for (int i < mKeys.Count)
		{
			if (mKeys[i] == from)
				mKeys[i].Set(to);
		}
	}

	public int Count => (mKind == .List || mKind == .Map) ? mItems.Count : 0;

	/// Compact JSON-like text: `{"a":1,"b":[true,null]}`.
	public override void ToString(String output)
	{
		switch (mKind)
		{
		case .Null: output.Append("null");
		case .Bool: output.Append(mBool ? "true" : "false");
		case .Integer: mInteger.ToString(output);
		case .UInteger: mUInteger.ToString(output);
		case .Float: mFloat.ToString(output);
		case .Text:
			output.Append('"');
			output.Append(mText);
			output.Append('"');
		case .List:
			output.Append('[');
			for (int i < mItems.Count)
			{
				if (i > 0)
					output.Append(',');
				mItems[i].ToString(output);
			}
			output.Append(']');
		case .Map:
			output.Append('{');
			for (int i < mItems.Count)
			{
				if (i > 0)
					output.Append(',');
				output.AppendF("\"{}\":", mKeys[i]);
				mItems[i].ToString(output);
			}
			output.Append('}');
		}
	}
}
