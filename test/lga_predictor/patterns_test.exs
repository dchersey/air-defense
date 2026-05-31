defmodule LgaPredictor.PatternsTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.Patterns

  test "all/0 returns the known patterns with required keys" do
    for p <- Patterns.all() do
      assert is_atom(p.id)
      assert is_binary(p.label)
      assert match?({_, _, _, _}, p.approach_box)
      assert p.reckoning in [:constant, :accelerating]
    end

    ids = Enum.map(Patterns.all(), & &1.id)
    assert :arrival_sw in ids
    assert :departure_arc in ids
  end

  test "get/1 finds by id and returns nil for unknown" do
    assert Patterns.get(:arrival_sw).label == "Arrivals (SW)"
    assert Patterns.get(:departure_arc).reckoning == :accelerating
    assert Patterns.get(:nope) == nil
  end

  test "union_box covers all pattern approach boxes" do
    {n, s, w, e} = Patterns.union_box()

    for %{approach_box: {pn, ps, pw, pe}} <- Patterns.all() do
      assert n >= pn
      assert s <= ps
      assert w <= pw
      assert e >= pe
    end
  end
end
