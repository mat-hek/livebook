defmodule Livebook.NotebookTest do
  use ExUnit.Case, async: true

  alias Livebook.Notebook
  alias Livebook.Notebook.{Section, Cell}

  describe "fetch_cell_sibling/3" do
    test "returns error given invalid cell id" do
      notebook = Notebook.new()

      assert :error == Notebook.fetch_cell_sibling(notebook, "1", 0)
    end

    test "returns sibling cell if there is one at the given offset" do
      cell1 = Cell.new(:markdown)
      cell2 = Cell.new(:markdown)
      cell3 = Cell.new(:markdown)
      cell4 = Cell.new(:markdown)

      notebook = %{
        Notebook.new()
        | sections: [
            %{Section.new() | cells: [cell1, cell2, cell3, cell4]}
          ]
      }

      assert {:ok, cell1} == Notebook.fetch_cell_sibling(notebook, cell2.id, -1)
      assert {:ok, cell3} == Notebook.fetch_cell_sibling(notebook, cell2.id, 1)
      assert {:ok, cell4} == Notebook.fetch_cell_sibling(notebook, cell2.id, 2)
    end

    test "returns error if the offset is out of range" do
      cell1 = Cell.new(:markdown)
      cell2 = Cell.new(:markdown)

      notebook = %{
        Notebook.new()
        | sections: [
            %{Section.new() | cells: [cell1, cell2]}
          ]
      }

      assert :error == Notebook.fetch_cell_sibling(notebook, cell2.id, -2)
      assert :error == Notebook.fetch_cell_sibling(notebook, cell2.id, 1)
      assert :error == Notebook.fetch_cell_sibling(notebook, cell2.id, 2)
    end
  end

  describe "move_cell/3" do
    test "preserves empty sections" do
      cell1 = Cell.new(:markdown)

      notebook = %{
        Notebook.new()
        | sections: [
            %{Section.new() | cells: [cell1]},
            %{Section.new() | cells: []}
          ]
      }

      new_notebook = Notebook.move_cell(notebook, cell1.id, 1)

      assert %{sections: [%{cells: []}, %{cells: [^cell1]}]} = new_notebook
    end
  end

  describe "cell_dependency_graph/1" do
    test "computes a linear graph for regular sections" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{Cell.new(:markdown) | id: "c1"},
                  %{Cell.new(:code) | id: "c2"}
                ]
            },
            %{
              Section.new()
              | id: "s2",
                cells: [
                  %{Cell.new(:markdown) | id: "c3"},
                  %{Cell.new(:code) | id: "c4"}
                ]
            }
          ]
      }

      assert Notebook.cell_dependency_graph(notebook) == %{
               "c4" => "c3",
               "c3" => "c2",
               "c2" => "c1",
               "c1" => "setup",
               "setup" => nil
             }
    end

    test "ignores empty sections" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{Section.new() | id: "s1", cells: [%{Cell.new(:code) | id: "c1"}]},
            %{Section.new() | id: "s2", cells: []},
            %{Section.new() | id: "s3", cells: [%{Cell.new(:code) | id: "c2"}]}
          ]
      }

      assert Notebook.cell_dependency_graph(notebook) == %{
               "c2" => "c1",
               "c1" => "setup",
               "setup" => nil
             }
    end

    test "computes a non-linear graph if there are branching sections" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{Cell.new(:code) | id: "c1"},
                  %{Cell.new(:code) | id: "c2"}
                ]
            },
            %{
              Section.new()
              | id: "s2",
                parent_id: "s1",
                cells: [
                  %{Cell.new(:code) | id: "c3"},
                  %{Cell.new(:code) | id: "c4"}
                ]
            },
            %{
              Section.new()
              | id: "s3",
                cells: [
                  %{Cell.new(:code) | id: "c5"},
                  %{Cell.new(:code) | id: "c6"}
                ]
            }
          ]
      }

      assert Notebook.cell_dependency_graph(notebook) == %{
               "c6" => "c5",
               "c5" => "c2",
               "c4" => "c3",
               "c3" => "c2",
               "c2" => "c1",
               "c1" => "setup",
               "setup" => nil
             }
    end

    test "handles branching sections pointing to empty sections" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{Cell.new(:code) | id: "c1"}
                ]
            },
            %{
              Section.new()
              | id: "s2",
                cells: []
            },
            %{
              Section.new()
              | id: "s3",
                parent_id: "s2",
                cells: [
                  %{Cell.new(:code) | id: "c2"}
                ]
            }
          ]
      }

      assert Notebook.cell_dependency_graph(notebook) == %{
               "c2" => "c1",
               "c1" => "setup",
               "setup" => nil
             }
    end

    test "handles branching sections placed further in the notebook" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{Cell.new(:code) | id: "c1"}
                ]
            },
            %{
              Section.new()
              | id: "s2",
                cells: [
                  %{Cell.new(:code) | id: "c2"}
                ]
            },
            %{
              Section.new()
              | id: "s3",
                parent_id: "s1",
                cells: [
                  %{Cell.new(:code) | id: "c3"}
                ]
            },
            %{
              Section.new()
              | id: "s4",
                cells: [
                  %{Cell.new(:code) | id: "c4"}
                ]
            }
          ]
      }

      assert Notebook.cell_dependency_graph(notebook) == %{
               "c4" => "c2",
               "c3" => "c1",
               "c2" => "c1",
               "c1" => "setup",
               "setup" => nil
             }
    end

    test "given :cell_filter option, includes only the matching cells" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{Cell.new(:code) | id: "c1"},
                  %{Cell.new(:markdown) | id: "c2"},
                  %{Cell.new(:code) | id: "c3"}
                ]
            }
          ]
      }

      assert Notebook.cell_dependency_graph(notebook, cell_filter: &Cell.evaluable?/1) ==
               %{
                 "c3" => "c1",
                 "c1" => "setup",
                 "setup" => nil
               }
    end
  end

  describe "find_asset_info/2" do
    test "returns asset info matching the given type if found" do
      assets_info = %{archive: "/path/to/archive.tar.gz", hash: "abcd", js_path: "main.js"}
      js_info = %{js_view: %{assets: assets_info}}
      output = {:js, js_info}

      notebook = %{
        Notebook.new()
        | sections: [%{Section.new() | cells: [%{Cell.new(:code) | outputs: [{0, output}]}]}]
      }

      assert ^assets_info = Notebook.find_asset_info(notebook, "abcd")
    end

    test "returns nil if no matching info is found" do
      notebook = Notebook.new()
      assert Notebook.find_asset_info(notebook, "abcd") == nil
    end
  end

  describe "add_cell_output/3" do
    test "merges consecutive text outputs when both are chunks" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{
                    Cell.new(:code)
                    | id: "c1",
                      outputs: [{0, {:terminal_text, "Hola", %{chunk: true}}}]
                  }
                ]
            }
          ],
          output_counter: 1
      }

      assert %{
               sections: [
                 %{
                   cells: [%{outputs: [{0, {:terminal_text, "Hola amigo!", %{chunk: true}}}]}]
                 }
               ]
             } =
               Notebook.add_cell_output(
                 notebook,
                 "c1",
                 {:terminal_text, " amigo!", %{chunk: true}}
               )
    end

    test "adds separate text outputs when they are not chunks" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{
                    Cell.new(:code)
                    | id: "c1",
                      outputs: [{0, {:terminal_text, "Hola", %{chunk: false}}}]
                  }
                ]
            }
          ],
          output_counter: 1
      }

      assert %{
               sections: [
                 %{
                   cells: [
                     %{
                       outputs: [
                         {1, {:terminal_text, " amigo!", %{chunk: true}}},
                         {0, {:terminal_text, "Hola", %{chunk: false}}}
                       ]
                     }
                   ]
                 }
               ]
             } =
               Notebook.add_cell_output(
                 notebook,
                 "c1",
                 {:terminal_text, " amigo!", %{chunk: true}}
               )
    end

    test "normalizes individual terminal text outputs to respect CR" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{Cell.new(:code) | id: "c1", outputs: []}
                ]
            }
          ],
          output_counter: 0
      }

      assert %{
               sections: [
                 %{
                   cells: [%{outputs: [{0, {:terminal_text, "Hey", %{chunk: false}}}]}]
                 }
               ]
             } =
               Notebook.add_cell_output(
                 notebook,
                 "c1",
                 {:terminal_text, "Hola\rHey", %{chunk: false}}
               )
    end

    test "normalizes consecutive terminal text outputs to respect CR" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{
                    Cell.new(:code)
                    | id: "c1",
                      outputs: [{0, {:terminal_text, "Hola", %{chunk: true}}}]
                  }
                ]
            }
          ],
          output_counter: 1
      }

      assert %{
               sections: [
                 %{
                   cells: [%{outputs: [{0, {:terminal_text, "amigo!\r", %{chunk: true}}}]}]
                 }
               ]
             } =
               Notebook.add_cell_output(
                 notebook,
                 "c1",
                 {:terminal_text, "\ramigo!\r", %{chunk: true}}
               )
    end

    test "updates existing frames on frame update output" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [
                  %{
                    Cell.new(:code)
                    | id: "c1",
                      outputs: [{0, {:frame, [], %{ref: "1", type: :default}}}]
                  },
                  %{
                    Cell.new(:code)
                    | id: "c2",
                      outputs: [{1, {:frame, [], %{ref: "1", type: :default}}}]
                  }
                ]
            }
          ],
          output_counter: 2
      }

      assert %{
               sections: [
                 %{
                   cells: [
                     %{
                       outputs: [
                         {0,
                          {:frame, [{2, {:terminal_text, "hola", %{chunk: false}}}],
                           %{ref: "1", type: :default}}}
                       ]
                     },
                     %{
                       outputs: [
                         {1,
                          {:frame, [{3, {:terminal_text, "hola", %{chunk: false}}}],
                           %{ref: "1", type: :default}}}
                       ]
                     }
                   ]
                 }
               ]
             } =
               Notebook.add_cell_output(
                 notebook,
                 "c2",
                 {:frame, [{:terminal_text, "hola", %{chunk: false}}],
                  %{ref: "1", type: :replace}}
               )
    end

    test "merges chunked text outputs in a new frame" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [%{Cell.new(:code) | id: "c1", outputs: []}]
            }
          ],
          output_counter: 0
      }

      assert %{
               sections: [
                 %{
                   cells: [
                     %{
                       outputs: [
                         {2,
                          {:frame, [{1, {:terminal_text, "hola amigo!", %{chunk: true}}}],
                           %{ref: "1", type: :default}}}
                       ]
                     }
                   ]
                 }
               ]
             } =
               Notebook.add_cell_output(
                 notebook,
                 "c1",
                 {:frame,
                  [
                    {:terminal_text, " amigo!", %{chunk: true}},
                    {:terminal_text, "hola", %{chunk: true}}
                  ], %{ref: "1", type: :default}}
               )
    end

    test "skips ignored output" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [%{Cell.new(:code) | id: "c1", outputs: []}]
            }
          ],
          output_counter: 1
      }

      assert %{
               sections: [
                 %{
                   cells: [%{outputs: []}]
                 }
               ]
             } = Notebook.add_cell_output(notebook, "c1", :ignored)
    end

    test "supports legacy text outputs" do
      notebook = %{
        Notebook.new()
        | sections: [
            %{
              Section.new()
              | id: "s1",
                cells: [%{Cell.new(:code) | id: "c1", outputs: []}]
            }
          ],
          output_counter: 0
      }

      assert %{
               sections: [
                 %{
                   cells: [%{outputs: [{0, {:terminal_text, "Hola", %{chunk: false}}}]}]
                 }
               ]
             } = Notebook.add_cell_output(notebook, "c1", {:text, "Hola"})

      assert %{
               sections: [
                 %{
                   cells: [%{outputs: [{0, {:markdown, "Hola", %{chunk: false}}}]}]
                 }
               ]
             } = Notebook.add_cell_output(notebook, "c1", {:markdown, "Hola"})
    end
  end

  describe "find_frame_outputs/2" do
    test "returns frame outputs with matching ref" do
      frame_output = {0, {:frame, [], %{ref: "1", type: :default}}}

      notebook = %{
        Notebook.new()
        | sections: [%{Section.new() | cells: [%{Cell.new(:code) | outputs: [frame_output]}]}]
      }

      assert [^frame_output] = Notebook.find_frame_outputs(notebook, "1")
    end

    test "finds a nested frame" do
      nested_frame_output = {0, {:frame, [], %{ref: "2", type: :default}}}
      frame_output = {0, {:frame, [nested_frame_output], %{ref: "1", type: :default}}}

      notebook = %{
        Notebook.new()
        | sections: [%{Section.new() | cells: [%{Cell.new(:code) | outputs: [frame_output]}]}]
      }

      assert [^nested_frame_output] = Notebook.find_frame_outputs(notebook, "2")
    end
  end
end
