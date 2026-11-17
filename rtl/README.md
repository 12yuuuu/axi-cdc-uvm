# RTL under test

All RTL here is copied in (vendored), so the testbench runs without Bender
or network access. Only the files the testbench compiles are included.
Every file keeps its original copyright and license header (Solderpad
Hardware License 0.51, SHL-0.51).

| Folder | Source | Version |
|---|---|---|
| `axi/` | [pulp-platform/axi](https://github.com/pulp-platform/axi) | commit `70b8e54fd460e3308e58be596ceb3566a6e3576e` |
| `common_cells/` | [pulp-platform/common_cells](https://github.com/pulp-platform/common_cells) | upstream `e73baaec2ca665cd80c3c384e9258e35242b829c` (these files are not changed by the PR below) |
| `tech_cells_generic/` | [pulp-platform/tech_cells_generic](https://github.com/pulp-platform/tech_cells_generic) | commit `55cb54513e2d426be5992d311cb9d5dbcad10c78` |
| `dut/cc_cdc_fifo_gray_ram.sv` | [pulp-platform/common_cells#369](https://github.com/pulp-platform/common_cells/pull/369), branch `cdc-fifo-gray-ram` of [12yuuuu/common_cells](https://github.com/12yuuuu/common_cells) | commit `318a93b9488481bdeb9f34bb7530acdcafee45e2` |
| `dut/axi_cdc_ram.sv` | prepared for pulp-platform/axi as the follow-up of [pulp-platform/axi#294](https://github.com/pulp-platform/axi/issues/294); not upstream yet | - |

The two files in `dut/` are the design under test (written by the author of
this repository for the PULP project, under PULP's license). `axi_cdc` from
`axi/` is the baseline: the testbench runs both with the same seeds.
