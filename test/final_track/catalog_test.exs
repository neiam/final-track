defmodule FinalTrack.CatalogTest do
  use FinalTrack.DataCase, async: true

  alias FinalTrack.Catalog

  test "normalize/1 folds case, spacing and Unicode forms" do
    assert Catalog.normalize("  The   BEATLES ") == "the beatles"
    assert Catalog.normalize("Ｓｉｇｕｒ Ｒóｓ") == Catalog.normalize("Sigur Rós")
  end

  test "one artist, album and track however the name is spelled; the first spelling stays" do
    a1 = Catalog.ensure_artist!("Boards of Canada")
    a2 = Catalog.ensure_artist!("boards  of canada")
    assert a1.id == a2.id
    assert a2.name == "Boards of Canada"

    assert Catalog.ensure_album!(a1, "Geogaddi").id == Catalog.ensure_album!(a2, "GEOGADDI").id

    assert Catalog.ensure_track!(a1, "Dawn Chorus").id ==
             Catalog.ensure_track!(a1, "dawn chorus").id
  end

  test "the same album title under two artists is two albums" do
    a = Catalog.ensure_artist!("A")
    b = Catalog.ensure_artist!("B")

    refute Catalog.ensure_album!(a, "Greatest Hits").id ==
             Catalog.ensure_album!(b, "Greatest Hits").id
  end

  test "a duration fills in a track that had none and never overwrites one" do
    artist = Catalog.ensure_artist!("A")
    assert Catalog.ensure_track!(artist, "T").duration_sec == nil
    assert Catalog.ensure_track!(artist, "T", 200).duration_sec == 200
    assert Catalog.ensure_track!(artist, "T", 999).duration_sec == 200
  end
end
