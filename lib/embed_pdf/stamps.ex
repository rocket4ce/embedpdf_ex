defmodule EmbedPdf.Stamps do
  @moduledoc """
  The standard rubber-stamp library, the same 17 stamps EmbedPDF ships
  (`@embedpdf/default-stamps`): identifiers, labels, colors and sizes.

  A placed stamp's `/Name` is the stamp's `name` (`"NotApproved"`), its
  `/Subj` the label. `get/1` accepts the id, the name or the label.
  """

  @green {0.2549, 0.41568, 0.1098}
  @red {0.56862, 0.05882, 0.01961}
  @blue {0.09412, 0.1451, 0.39215}
  @amber {0.81, 0.69, 0.13}

  @stamps [
    %{
      id: "approved",
      name: "Approved",
      label: "Approved",
      color: @green,
      size: {163.5, 49.5},
      kind: :box
    },
    %{
      id: "not-approved",
      name: "NotApproved",
      label: "Not Approved",
      color: @red,
      size: {218.6, 49.5},
      kind: :box
    },
    %{id: "draft", name: "Draft", label: "Draft", color: @blue, size: {113.1, 49.7}, kind: :box},
    %{id: "final", name: "Final", label: "Final", color: @green, size: {97.8, 49.7}, kind: :box},
    %{
      id: "completed",
      name: "Completed",
      label: "Completed",
      color: @green,
      size: {175.9, 49.5},
      kind: :box
    },
    %{
      id: "confidential",
      name: "Confidential",
      label: "Confidential",
      color: @blue,
      size: {209.6, 49.5},
      kind: :box
    },
    %{
      id: "for-public-release",
      name: "ForPublicRelease",
      label: "For Public Release",
      color: @blue,
      size: {290.0, 49.6},
      kind: :box
    },
    %{
      id: "not-for-public-release",
      name: "NotForPublicRelease",
      label: "Not for Public Release",
      color: @blue,
      size: {346.0, 49.6},
      kind: :box
    },
    %{
      id: "for-comment",
      name: "ForComment",
      label: "For Comment",
      color: @blue,
      size: {211.9, 49.5},
      kind: :box
    },
    %{id: "void", name: "Void", label: "Void", color: @red, size: {91.0, 49.7}, kind: :box},
    %{
      id: "preliminary-results",
      name: "PreliminaryResults",
      label: "Preliminary Results",
      color: @blue,
      size: {304.0, 49.6},
      kind: :box
    },
    %{
      id: "information-only",
      name: "InformationOnly",
      label: "Information Only",
      color: @blue,
      size: {275.0, 49.6},
      kind: :box
    },
    %{
      id: "witness",
      name: "Witness",
      label: "Witness",
      color: @amber,
      size: {99.7, 30.3},
      kind: :sign
    },
    %{
      id: "initial-here",
      name: "InitialHere",
      label: "Initial Here",
      color: @amber,
      size: {99.7, 30.3},
      kind: :sign
    },
    %{
      id: "sign-here",
      name: "SignHere",
      label: "Sign Here",
      color: @amber,
      size: {99.7, 30.3},
      kind: :sign
    },
    %{
      id: "accepted",
      name: "Accepted",
      label: "Accepted",
      color: @green,
      size: {23.3, 20.5},
      kind: :check
    },
    %{
      id: "rejected",
      name: "Rejected",
      label: "Rejected",
      color: @red,
      size: {22.7, 22.7},
      kind: :cross
    }
  ]

  @doc "All stamps: `%{id, name, label, color, size: {w, h}, kind}`."
  @spec list() :: [map()]
  def list, do: @stamps

  @doc "A stamp by id, `/Name` or label (case-insensitive), or nil."
  @spec get(String.t() | nil) :: map() | nil
  def get(nil), do: nil

  def get(key) do
    k = key |> String.downcase() |> String.replace(~r/[\s_#]+/, "")

    Enum.find(@stamps, fn s ->
      Enum.any?([s.id, s.name, s.label], fn v ->
        v |> String.downcase() |> String.replace(~r/[\s_]+/, "") == k
      end) or
        String.replace(s.id, "-", "") == String.replace(k, "-", "")
    end)
  end
end
