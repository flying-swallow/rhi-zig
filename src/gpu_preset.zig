const physical_adapter = @import("physical_adapter.zig");

pub const Preset = struct {
  vendor_id: u32,
  model_id: u32,
  preset_level: physical_adapter.PresetLevel 
};

pub const desktop_presets = [_]Preset{
//#intel
.{ .vendor_id = 0x8086, .model_id = 0x0042, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics - Core i3/i5 + Pentium G9650 Processors
.{ .vendor_id = 0x8086, .model_id = 0x0046, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics - Core i3/i5/i7 Mobile Processors
.{ .vendor_id = 0x8086, .model_id = 0x0102, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 2000
.{ .vendor_id = 0x8086, .model_id = 0x0106, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 2000
.{ .vendor_id = 0x8086, .model_id = 0x010A, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0112, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 3000
.{ .vendor_id = 0x8086, .model_id = 0x0116, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 3000
.{ .vendor_id = 0x8086, .model_id = 0x0122, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 3000
.{ .vendor_id = 0x8086, .model_id = 0x0126, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 3000
.{ .vendor_id = 0x8086, .model_id = 0x0152, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 2500
.{ .vendor_id = 0x8086, .model_id = 0x0156, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 2500
.{ .vendor_id = 0x8086, .model_id = 0x015A, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 2500
.{ .vendor_id = 0x8086, .model_id = 0x0162, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 4000
.{ .vendor_id = 0x8086, .model_id = 0x0166, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 4000
.{ .vendor_id = 0x8086, .model_id = 0x016A, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 4000
.{ .vendor_id = 0x8086, .model_id = 0x0402, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0406, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x040A, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x040B, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x040E, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0412, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 4600
.{ .vendor_id = 0x8086, .model_id = 0x0416, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 4600
.{ .vendor_id = 0x8086, .model_id = 0x041A, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics P4600/P4700
.{ .vendor_id = 0x8086, .model_id = 0x041B, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x041E, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0422, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 5000
.{ .vendor_id = 0x8086, .model_id = 0x0426, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 5000
.{ .vendor_id = 0x8086, .model_id = 0x042A, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics 5000
.{ .vendor_id = 0x8086, .model_id = 0x042B, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x042E, .preset_level = .very_low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0900, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0901, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0902, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0903, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0904, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0A02, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0BD0, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0BD1, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0BD2, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0BD3, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0BD4, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C02, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C06, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C0A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C12, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C16, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C1A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C22, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C26, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0C2A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0F30, .preset_level = .very_low}, //Intel; Intel(R) Vallyview Graphics
.{ .vendor_id = 0x8086, .model_id = 0x0F31, .preset_level = .very_low}, //Intel; Intel(R) Vallyview Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1602, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1606, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x160A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x160B, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x160D, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x160E, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1612, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 5600
.{ .vendor_id = 0x8086, .model_id = 0x1616, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 5500
.{ .vendor_id = 0x8086, .model_id = 0x161A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x161B, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x161D, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x161E, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 5300
.{ .vendor_id = 0x8086, .model_id = 0x1622, .preset_level = .very_low}, //Intel; Intel(R) Iris(TM) Pro Graphics 6200
.{ .vendor_id = 0x8086, .model_id = 0x1626, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 6000
.{ .vendor_id = 0x8086, .model_id = 0x162A, .preset_level = .very_low}, //Intel; Intel(R) Iris(TM) Pro Graphics P6300
.{ .vendor_id = 0x8086, .model_id = 0x162B, .preset_level = .very_low}, //Intel; Intel(R) Iris(TM) Graphics 6100
.{ .vendor_id = 0x8086, .model_id = 0x162D, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x162E, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1632, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1636, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x163A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x163B, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x163D, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x163E, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1902, .preset_level = .low }, //Intel; Intel(R) HD Graphics 510
.{ .vendor_id = 0x8086, .model_id = 0x1906, .preset_level = .low }, //Intel; Intel(R) HD Graphics 510
.{ .vendor_id = 0x8086, .model_id = 0x190A, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x190B, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x190E, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1912, .preset_level = .low }, //Intel; Intel(R) HD Graphics 530
.{ .vendor_id = 0x8086, .model_id = 0x1913, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1916, .preset_level = .low }, //Intel; Intel(R) HD Graphics 520
.{ .vendor_id = 0x8086, .model_id = 0x191A, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x191B, .preset_level = .low }, //Intel; Intel(R) HD Graphics 530
.{ .vendor_id = 0x8086, .model_id = 0x191D, .preset_level = .low }, //Intel; Intel(R) HD Graphics P530
.{ .vendor_id = 0x8086, .model_id = 0x191E, .preset_level = .low }, //Intel; Intel(R) HD Graphics 515
.{ .vendor_id = 0x8086, .model_id = 0x1921, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1923, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x1926, .preset_level = .low }, //Intel; Intel(R) Iris Graphics 540
.{ .vendor_id = 0x8086, .model_id = 0x1927, .preset_level = .low }, //Intel; Intel(R) Iris Graphics 540
.{ .vendor_id = 0x8086, .model_id = 0x192A, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x192B, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x192D, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x193A, .preset_level = .low }, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x193B, .preset_level = .medium}, //Intel; Intel(R) Iris Pro Graphics 580
.{ .vendor_id = 0x8086, .model_id = 0x193D, .preset_level = .medium}, //Intel; Intel(R) Iris Pro Graphics P580
.{ .vendor_id = 0x8086, .model_id = 0x22B0, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x22B1, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x22B2, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x22B3, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x2982, .preset_level = .very_low}, //Intel; Intel(R) G35 Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2983, .preset_level = .very_low}, //Intel; Intel(R) G35 Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2A02, .preset_level = .very_low}, //Intel; Mobile Intel(R) 965 Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2A03, .preset_level = .very_low}, //Intel; Mobile Intel(R) 965 Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2A12, .preset_level = .very_low}, //Intel; Mobile Intel(R) 965 Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2A13, .preset_level = .very_low}, //Intel; Mobile Intel(R) 965 Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2A42, .preset_level = .very_low}, //Intel; Mobile Intel(R) 4 Series Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2A43, .preset_level = .very_low}, //Intel; Mobile Intel(R) 4 Series Express Chipset Family
.{ .vendor_id = 0x8086, .model_id = 0x2E02, .preset_level = .very_low}, //Intel; Intel(R) 4 Series Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E03, .preset_level = .very_low}, //Intel; Intel(R) 4 Series Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E12, .preset_level = .very_low}, //Intel; Intel(R) Q45/Q43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E13, .preset_level = .very_low}, //Intel; Intel(R) Q45/Q43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E22, .preset_level = .very_low}, //Intel; Intel(R) G45/G43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E23, .preset_level = .very_low}, //Intel; Intel(R) G45/G43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E32, .preset_level = .very_low}, //Intel; Intel(R) G41 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E33, .preset_level = .very_low}, //Intel; Intel(R) G41 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E42, .preset_level = .very_low}, //Intel; Intel(R) B43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E43, .preset_level = .very_low}, //Intel; Intel(R) B43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E92, .preset_level = .very_low}, //Intel; Intel(R) B43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x2E93, .preset_level = .very_low}, //Intel; Intel(R) B43 Express Chipset
.{ .vendor_id = 0x8086, .model_id = 0x3184, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3185, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E90, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E91, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E92, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E93, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E94, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E96, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E98, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E99, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E9A, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E9B, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3E9C, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA0, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA1, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA2, .preset_level = .medium}, //Intel; Intel(R) Iris Plus Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA3, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA4, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA5, .preset_level = .medium}, //Intel; Intel(R) Iris Plus Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA6, .preset_level = .medium}, //Intel; Intel(R) Iris Plus Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA7, .preset_level = .medium}, //Intel; Intel(R) Iris Plus Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA8, .preset_level = .medium}, //Intel; Intel(R) Iris Plus Graphics
.{ .vendor_id = 0x8086, .model_id = 0x3EA9, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4626, .preset_level = .low }, //Intel; , Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4680, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4682, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4688, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x468A, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x468B, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4690, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4692, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4693, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x46A3, .preset_level = .low }, //Intel; , Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x46A6, .preset_level = .low }, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4905, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe MAX Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4906, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe MAX Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4907, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe MAX Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4C8A, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4C8B, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x4C90, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5690, .preset_level = .medium}, //Intel; Intel(R) Arc(TM) A770M Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5693, .preset_level = .medium}, //Intel; Intel(R) Arc(TM) A370M Graphics
.{ .vendor_id = 0x8086, .model_id = 0x56A0, .preset_level = .medium}, //Intel; Intel(R) Arc(TM) A770 Graphics
.{ .vendor_id = 0x8086, .model_id = 0x56A1, .preset_level = .medium}, //Intel; Intel(R) Arc(TM) A750 Graphics
.{ .vendor_id = 0x8086, .model_id = 0x56A5, .preset_level = .medium}, //Intel; Intel(R) Arc(TM) A380 Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5902, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 610
.{ .vendor_id = 0x8086, .model_id = 0x5906, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 610
.{ .vendor_id = 0x8086, .model_id = 0x5908, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x590A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x590B, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics P610
.{ .vendor_id = 0x8086, .model_id = 0x590E, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5912, .preset_level = .low }, //Intel; Intel(R) HD Graphics 630
.{ .vendor_id = 0x8086, .model_id = 0x5913, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5915, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5916, .preset_level = .low }, //Intel; Intel(R) HD Graphics 620
.{ .vendor_id = 0x8086, .model_id = 0x5917, .preset_level = .low }, //Intel; Intel(R) UHD Graphics 620
.{ .vendor_id = 0x8086, .model_id = 0x591A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x591B, .preset_level = .low }, //Intel; Intel(R) HD Graphics 630
.{ .vendor_id = 0x8086, .model_id = 0x591C, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x591D, .preset_level = .low }, //Intel; Intel(R) HD Graphics P630
.{ .vendor_id = 0x8086, .model_id = 0x591E, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics 615
.{ .vendor_id = 0x8086, .model_id = 0x5921, .preset_level = .low }, //Intel; Intel(R) HD Graphics 620
.{ .vendor_id = 0x8086, .model_id = 0x5923, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5926, .preset_level = .medium}, //Intel; Intel(R) Iris Plus Graphics 640
.{ .vendor_id = 0x8086, .model_id = 0x5927, .preset_level = .medium}, //Intel; Intel(R) Iris Plus Graphics 650
.{ .vendor_id = 0x8086, .model_id = 0x592A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x592B, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5932, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x593A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x593B, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x593D, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A40, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A41, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A42, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A44, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A49, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A4A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A4C, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A50, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A51, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A52, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A54, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A59, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A5A, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x5A5C, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x87C0, .preset_level = .very_low}, //Intel; Intel(R) HD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x87CA, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x8A50, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (64 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A51, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (64 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A52, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (64 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A53, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (64 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A54, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (48 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A56, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (48 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A57, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (48 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A58, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (32 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A59, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (48 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A5A, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (48 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A5B, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (32 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A5C, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (48 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A5D, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (32 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x8A71, .preset_level = .low }, //Intel; Intel(R) Iris Plus Graphics (8 EUs)
.{ .vendor_id = 0x8086, .model_id = 0x9A40, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9A49, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9A59, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9A60, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9A68, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9A70, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9A78, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9A7F, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9AC0, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9AC9, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9AD9, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9AF8, .preset_level = .low }, //Intel; Intel(R) Iris(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9B21, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9B41, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BA0, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BA2, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BA4, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BA5, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BA8, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BAA, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BAB, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BAC, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BC0, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BC2, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BC4, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BC5, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BC6, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BC8, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BCA, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BCB, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BCC, .preset_level = .low }, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BE6, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0x9BF6, .preset_level = .very_low}, //Intel; Intel(R) UHD Graphics
.{ .vendor_id = 0x8086, .model_id = 0xA780, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics
.{ .vendor_id = 0x8086, .model_id = 0xA788, .preset_level = .medium}, //Intel; Intel(R) Xe Graphics

// amd
.{ .vendor_id = 0x1002, .model_id = 0x1309, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R7 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x130A, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R6 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x130D, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R6 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x130F, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R7 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x1313, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R7 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x15BF, .preset_level = .very_low}, //AMD; AMD Radeon (TM) 740M Graphics
.{ .vendor_id = 0x1002, .model_id = 0x15D8, .preset_level = .very_low}, //AMD; AMD 15D8:C8
.{ .vendor_id = 0x1002, .model_id = 0x15DD, .preset_level = .very_low}, //AMD; AMD Radeon(TM) RX Vega 10 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x15E7, .preset_level = .very_low}, //AMD; AMD Radeon (TM) Graphics
.{ .vendor_id = 0x1002, .model_id = 0x163F, .preset_level = .very_low}, //AMD; AMD Custom GPU 0405
.{ .vendor_id = 0x1002, .model_id = 0x164E, .preset_level = .very_low}, //AMD; AMD Radeon(TM) 610M
.{ .vendor_id = 0x1002, .model_id = 0x1681, .preset_level = .very_low}, //AMD; AMD Radeon (TM) Graphics
.{ .vendor_id = 0x1002, .model_id = 0x6600, .preset_level = .very_low}, //AMD; AMD Radeon (TM) R7 M370
.{ .vendor_id = 0x1002, .model_id = 0x6601, .preset_level = .very_low}, //AMD; AMD Radeon (TM) HD 8500M/8700M
.{ .vendor_id = 0x1002, .model_id = 0x6604, .preset_level = .very_low}, //AMD; AMD Radeon (TM) R7 M350
.{ .vendor_id = 0x1002, .model_id = 0x6605, .preset_level = .very_low}, //AMD; AMD FirePro M4150
.{ .vendor_id = 0x1002, .model_id = 0x6606, .preset_level = .very_low}, //AMD; AMD Radeon HD 8790M
.{ .vendor_id = 0x1002, .model_id = 0x6608, .preset_level = .very_low}, //AMD; AMD FirePro W2100
.{ .vendor_id = 0x1002, .model_id = 0x6610, .preset_level = .very_low}, //AMD; AMD Radeon (TM) R5 340
.{ .vendor_id = 0x1002, .model_id = 0x6611, .preset_level = .very_low}, //AMD; AMD Radeon HD 8570
.{ .vendor_id = 0x1002, .model_id = 0x6613, .preset_level = .very_low}, //AMD; AMD Radeon R7 240
.{ .vendor_id = 0x1002, .model_id = 0x6640, .preset_level = .very_low}, //AMD; AMD FirePro M6100
.{ .vendor_id = 0x1002, .model_id = 0x6646, .preset_level = .very_low}, //AMD; AMD Radeon (TM) R9 M470X
.{ .vendor_id = 0x1002, .model_id = 0x6660, .preset_level = .very_low}, //AMD; AMD Radeon (TM) 520
.{ .vendor_id = 0x1002, .model_id = 0x6665, .preset_level = .very_low}, //AMD; AMD Radeon (TM) R5 M320
.{ .vendor_id = 0x1002, .model_id = 0x666F, .preset_level = .very_low}, //AMD; AMD Radeon HD 8500M
.{ .vendor_id = 0x1002, .model_id = 0x66A1, .preset_level = .medium}, //AMD; AMD Radeon Pro VII
.{ .vendor_id = 0x1002, .model_id = 0x66AF, .preset_level = .high}, //AMD; AMD Radeon VII
.{ .vendor_id = 0x1002, .model_id = 0x67A0, .preset_level = .very_low}, //AMD; AMD FirePro S9150
.{ .vendor_id = 0x1002, .model_id = 0x67B0, .preset_level = .low }, //AMD; AMD Radeon(TM) R9 290X
.{ .vendor_id = 0x1002, .model_id = 0x67C4, .preset_level = .medium}, //AMD; AMD Radeon (TM) Pro WX 7100 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x67C7, .preset_level = .low }, //AMD; Radeon (TM) Pro WX 5100 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x67DF, .preset_level = .medium}, //AMD; AMD Radeon (TM) RX 480
.{ .vendor_id = 0x1002, .model_id = 0x67E3, .preset_level = .very_low}, //AMD; Radeon (TM) Pro WX 4100
.{ .vendor_id = 0x1002, .model_id = 0x67E8, .preset_level = .very_low}, //AMD; Radeon(TM) Pro WX 4150 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x67EF, .preset_level = .very_low}, //AMD; AMD Radeon Pro 460
.{ .vendor_id = 0x1002, .model_id = 0x6801, .preset_level = .very_low}, //AMD; AMD Radeon(TM) HD8970M
.{ .vendor_id = 0x1002, .model_id = 0x6808, .preset_level = .low }, //AMD; AMD FirePro W7000
.{ .vendor_id = 0x1002, .model_id = 0x6810, .preset_level = .very_low}, //AMD; AMD FirePro D300
.{ .vendor_id = 0x1002, .model_id = 0x6820, .preset_level = .very_low}, //AMD; AMD FirePro W5170M
.{ .vendor_id = 0x1002, .model_id = 0x6821, .preset_level = .very_low}, //AMD; AMD FirePro M5100
.{ .vendor_id = 0x1002, .model_id = 0x682B, .preset_level = .very_low}, //AMD; AMD Radeon (TM) R9 M360
.{ .vendor_id = 0x1002, .model_id = 0x682C, .preset_level = .very_low}, //AMD; AMD FirePro W4100
.{ .vendor_id = 0x1002, .model_id = 0x683D, .preset_level = .very_low}, //AMD; AMD Radeon HD 7770 GHz Edition
.{ .vendor_id = 0x1002, .model_id = 0x6861, .preset_level = .medium}, //AMD; Radeon (TM) Pro WX 9100
.{ .vendor_id = 0x1002, .model_id = 0x6863, .preset_level = .medium}, //AMD; Radeon Vega Frontier Edition
.{ .vendor_id = 0x1002, .model_id = 0x6869, .preset_level = .medium}, //AMD; Radeon Pro Vega 48
.{ .vendor_id = 0x1002, .model_id = 0x686B, .preset_level = .medium}, //AMD; Radeon Pro Vega 64X
.{ .vendor_id = 0x1002, .model_id = 0x687F, .preset_level = .medium}, //AMD; Radeon RX Vega
.{ .vendor_id = 0x1002, .model_id = 0x6900, .preset_level = .very_low}, //AMD; AMD Radeon (TM) 535DX
.{ .vendor_id = 0x1002, .model_id = 0x6901, .preset_level = .very_low}, //AMD; AMD Radeon R5 M255
.{ .vendor_id = 0x1002, .model_id = 0x6920, .preset_level = .low }, //AMD; AMD RADEON R9 M395X
.{ .vendor_id = 0x1002, .model_id = 0x6929, .preset_level = .very_low}, //AMD; AMD FirePro S7150
.{ .vendor_id = 0x1002, .model_id = 0x692B, .preset_level = .low }, //AMD; AMD FirePro W7100
.{ .vendor_id = 0x1002, .model_id = 0x6938, .preset_level = .low }, //AMD; AMD RADEON R9 M295X
.{ .vendor_id = 0x1002, .model_id = 0x694C, .preset_level = .low }, //AMD; Radeon RX Vega M GH Graphics
.{ .vendor_id = 0x1002, .model_id = 0x694E, .preset_level = .very_low}, //AMD; Radeon RX Vega M GL Graphics
.{ .vendor_id = 0x1002, .model_id = 0x699F, .preset_level = .very_low}, //AMD; AMD Embedded Radeon E9175
.{ .vendor_id = 0x1002, .model_id = 0x69AF, .preset_level = .low }, //AMD; Radeon Pro Vega 20
.{ .vendor_id = 0x1002, .model_id = 0x6FDF, .preset_level = .low }, //AMD; AMD Radeon RX 580 2048SP
.{ .vendor_id = 0x1002, .model_id = 0x7300, .preset_level = .medium}, //AMD; Radeon (TM) Pro Duo
.{ .vendor_id = 0x1002, .model_id = 0x7312, .preset_level = .medium}, //AMD; AMD Radeon Pro W5700
.{ .vendor_id = 0x1002, .model_id = 0x731F, .preset_level = .medium}, //AMD; AMD Radeon RX 5600 XT
.{ .vendor_id = 0x1002, .model_id = 0x7340, .preset_level = .low }, //AMD; AMD Radeon Pro 5300
.{ .vendor_id = 0x1002, .model_id = 0x7341, .preset_level = .medium}, //AMD; AMD Radeon Pro W5500
.{ .vendor_id = 0x1002, .model_id = 0x7360, .preset_level = .medium}, //AMD; AMD Radeon Pro 5600M
.{ .vendor_id = 0x1002, .model_id = 0x7362, .preset_level = .low }, //AMD; AMD Radeon Pro V520 MxGPU
.{ .vendor_id = 0x1002, .model_id = 0x73A3, .preset_level = .high}, //AMD; AMD Radeon PRO W6800
.{ .vendor_id = 0x1002, .model_id = 0x73A5, .preset_level = .high}, //AMD; AMD Radeon RX 6950 XT
.{ .vendor_id = 0x1002, .model_id = 0x73AB, .preset_level = .low }, //AMD; AMD Radeon Pro W6800X
.{ .vendor_id = 0x1002, .model_id = 0x73AF, .preset_level = .high}, //AMD; AMD Radeon RX 6900 XT
.{ .vendor_id = 0x1002, .model_id = 0x73BF, .preset_level = .high}, //AMD; AMD Radeon RX 6800
.{ .vendor_id = 0x1002, .model_id = 0x73DF, .preset_level = .high}, //AMD; AMD Radeon RX 6700
.{ .vendor_id = 0x1002, .model_id = 0x73E3, .preset_level = .high}, //AMD; AMD Radeon PRO W6600
.{ .vendor_id = 0x1002, .model_id = 0x73EF, .preset_level = .high}, //AMD; AMD Radeon RX 6650 XT
.{ .vendor_id = 0x1002, .model_id = 0x73FF, .preset_level = .medium}, //AMD; AMD Radeon RX 6600
.{ .vendor_id = 0x1002, .model_id = 0x7422, .preset_level = .medium}, //AMD; AMD Radeon PRO W6400
.{ .vendor_id = 0x1002, .model_id = 0x743F, .preset_level = .low }, //AMD; AMD Radeon RX 6400
.{ .vendor_id = 0x1002, .model_id = 0x744C, .preset_level = .high}, //AMD; AMD Radeon RX 7900 XT
.{ .vendor_id = 0x1002, .model_id = 0x747E, .preset_level = .high}, //AMD; AMD Radeon RX 7700 XT
.{ .vendor_id = 0x1002, .model_id = 0x7480, .preset_level = .high}, //AMD; AMD Radeon RX 7600
.{ .vendor_id = 0x1002, .model_id = 0x9832, .preset_level = .very_low}, //AMD; AMD Radeon HD 8330
.{ .vendor_id = 0x1002, .model_id = 0x9834, .preset_level = .office }, //AMD; AMD Radeon HD 8210
.{ .vendor_id = 0x1002, .model_id = 0x9850, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R2 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x9851, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R4 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x9853, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R2 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x9874, .preset_level = .very_low}, //AMD; AMD Radeon R5 Graphics
.{ .vendor_id = 0x1002, .model_id = 0x98E4, .preset_level = .very_low}, //AMD; AMD Radeon(TM) R2 Graphics

// #nvidia
.{ .vendor_id = 0x10DE, .model_id = 0x1001, .preset_level = .medium}, //NVIDIA; GeForce GTX TITAN Z
.{ .vendor_id = 0x10DE, .model_id = 0x1004, .preset_level = .medium}, //NVIDIA; GeForce GTX 780
.{ .vendor_id = 0x10DE, .model_id = 0x1005, .preset_level = .medium}, //NVIDIA; GeForce GTX TITAN
.{ .vendor_id = 0x10DE, .model_id = 0x100A, .preset_level = .medium}, //NVIDIA; GeForce GTX 780 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x100C, .preset_level = .medium}, //NVIDIA; GeForce GTX TITAN Black
.{ .vendor_id = 0x10DE, .model_id = 0x1023, .preset_level = .very_low}, //NVIDIA; Tesla K40m
.{ .vendor_id = 0x10DE, .model_id = 0x103A, .preset_level = .medium}, //NVIDIA; Quadro K6000
.{ .vendor_id = 0x10DE, .model_id = 0x103C, .preset_level = .low }, //NVIDIA; Quadro K5200
.{ .vendor_id = 0x10DE, .model_id = 0x1180, .preset_level = .low }, //NVIDIA; GeForce GTX 680
.{ .vendor_id = 0x10DE, .model_id = 0x1183, .preset_level = .low }, //NVIDIA; GeForce GTX 660 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1184, .preset_level = .low }, //NVIDIA; GeForce GTX 770
.{ .vendor_id = 0x10DE, .model_id = 0x1185, .preset_level = .low }, //NVIDIA; GeForce GTX 660
.{ .vendor_id = 0x10DE, .model_id = 0x1187, .preset_level = .low }, //NVIDIA; GeForce GTX 760
.{ .vendor_id = 0x10DE, .model_id = 0x1188, .preset_level = .low }, //NVIDIA; GeForce GTX 690
.{ .vendor_id = 0x10DE, .model_id = 0x1189, .preset_level = .low }, //NVIDIA; GeForce GTX 670
.{ .vendor_id = 0x10DE, .model_id = 0x118E, .preset_level = .low }, //NVIDIA; GeForce GTX 760 (192-bit)
.{ .vendor_id = 0x10DE, .model_id = 0x1198, .preset_level = .very_low}, //NVIDIA; GeForce GTX 880M
.{ .vendor_id = 0x10DE, .model_id = 0x1199, .preset_level = .very_low}, //NVIDIA; GeForce GTX 870M
.{ .vendor_id = 0x10DE, .model_id = 0x119A, .preset_level = .very_low}, //NVIDIA; GeForce GTX 860M
.{ .vendor_id = 0x10DE, .model_id = 0x119E, .preset_level = .very_low}, //NVIDIA; GeForce GTX 780M
.{ .vendor_id = 0x10DE, .model_id = 0x119F, .preset_level = .very_low}, //NVIDIA; GeForce GTX 780M
.{ .vendor_id = 0x10DE, .model_id = 0x11A1, .preset_level = .very_low}, //NVIDIA; GeForce GTX 670MX
.{ .vendor_id = 0x10DE, .model_id = 0x11A3, .preset_level = .low }, //NVIDIA; GeForce GTX 680MX
.{ .vendor_id = 0x10DE, .model_id = 0x11A7, .preset_level = .very_low}, //NVIDIA; GeForce GTX 675MX
.{ .vendor_id = 0x10DE, .model_id = 0x11B4, .preset_level = .low }, //NVIDIA; Quadro K4200
.{ .vendor_id = 0x10DE, .model_id = 0x11B6, .preset_level = .very_low}, //NVIDIA; Quadro K3100M
.{ .vendor_id = 0x10DE, .model_id = 0x11B7, .preset_level = .very_low}, //NVIDIA; Quadro K4100M
.{ .vendor_id = 0x10DE, .model_id = 0x11B8, .preset_level = .very_low}, //NVIDIA; Quadro K5100M
.{ .vendor_id = 0x10DE, .model_id = 0x11BC, .preset_level = .very_low}, //NVIDIA; Quadro K5000M
.{ .vendor_id = 0x10DE, .model_id = 0x11BE, .preset_level = .very_low}, //NVIDIA; Quadro K3000M
.{ .vendor_id = 0x10DE, .model_id = 0x11C0, .preset_level = .low }, //NVIDIA; GeForce GTX 660
.{ .vendor_id = 0x10DE, .model_id = 0x11C2, .preset_level = .very_low}, //NVIDIA; GeForce GTX 650 Ti BOOST
.{ .vendor_id = 0x10DE, .model_id = 0x11C4, .preset_level = .very_low}, //NVIDIA; GeForce GTX 645
.{ .vendor_id = 0x10DE, .model_id = 0x11C6, .preset_level = .very_low}, //NVIDIA; GeForce GTX 650 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x11C8, .preset_level = .very_low}, //NVIDIA; GeForce GTX 650
.{ .vendor_id = 0x10DE, .model_id = 0x11E0, .preset_level = .very_low}, //NVIDIA; GeForce GTX 770M
.{ .vendor_id = 0x10DE, .model_id = 0x11E1, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce GTX 765M
.{ .vendor_id = 0x10DE, .model_id = 0x11E2, .preset_level = .very_low}, //NVIDIA; GeForce GTX 765M
.{ .vendor_id = 0x10DE, .model_id = 0x11E3, .preset_level = .very_low}, //NVIDIA; GeForce GTX 760M
.{ .vendor_id = 0x10DE, .model_id = 0x11FA, .preset_level = .very_low}, //NVIDIA; Quadro K4000
.{ .vendor_id = 0x10DE, .model_id = 0x11FC, .preset_level = .very_low}, //NVIDIA; K2100M
.{ .vendor_id = 0x10DE, .model_id = 0x1280, .preset_level = .very_low}, //NVIDIA; GeForce GT 635
.{ .vendor_id = 0x10DE, .model_id = 0x1281, .preset_level = .very_low}, //NVIDIA; GT 710
.{ .vendor_id = 0x10DE, .model_id = 0x1282, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce GT 640
.{ .vendor_id = 0x10DE, .model_id = 0x1284, .preset_level = .very_low}, //NVIDIA; GeForce GT 630
.{ .vendor_id = 0x10DE, .model_id = 0x1286, .preset_level = .very_low}, //NVIDIA; GeForce GT 720
.{ .vendor_id = 0x10DE, .model_id = 0x1287, .preset_level = .very_low}, //NVIDIA; GeForce GT 730
.{ .vendor_id = 0x10DE, .model_id = 0x1288, .preset_level = .very_low}, //NVIDIA; GeForce GT 720
.{ .vendor_id = 0x10DE, .model_id = 0x128B, .preset_level = .very_low}, //NVIDIA; GeForce GT 710
.{ .vendor_id = 0x10DE, .model_id = 0x1290, .preset_level = .very_low}, //NVIDIA; GeForce GT 730M
.{ .vendor_id = 0x10DE, .model_id = 0x1292, .preset_level = .very_low}, //NVIDIA; GeForce GT 740M
.{ .vendor_id = 0x10DE, .model_id = 0x1295, .preset_level = .very_low}, //NVIDIA; GeForce 810A
.{ .vendor_id = 0x10DE, .model_id = 0x1299, .preset_level = .very_low}, //NVIDIA; 920M
.{ .vendor_id = 0x10DE, .model_id = 0x129A, .preset_level = .very_low}, //NVIDIA; GeForce 910M
.{ .vendor_id = 0x10DE, .model_id = 0x12B9, .preset_level = .very_low}, //NVIDIA; Quadro K610M
.{ .vendor_id = 0x10DE, .model_id = 0x1340, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce 830M
.{ .vendor_id = 0x10DE, .model_id = 0x1341, .preset_level = .very_low}, //NVIDIA; 840M
.{ .vendor_id = 0x10DE, .model_id = 0x1344, .preset_level = .very_low}, //NVIDIA; GeForce 845M
.{ .vendor_id = 0x10DE, .model_id = 0x1346, .preset_level = .very_low}, //NVIDIA; GeForce 930M
.{ .vendor_id = 0x10DE, .model_id = 0x1347, .preset_level = .very_low}, //NVIDIA; GeForce 940M
.{ .vendor_id = 0x10DE, .model_id = 0x134B, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce GPU
.{ .vendor_id = 0x10DE, .model_id = 0x134D, .preset_level = .very_low}, //NVIDIA; GeForce 940MX
.{ .vendor_id = 0x10DE, .model_id = 0x134E, .preset_level = .very_low}, //NVIDIA; 930MX
.{ .vendor_id = 0x10DE, .model_id = 0x134F, .preset_level = .very_low}, //NVIDIA; 920MX
.{ .vendor_id = 0x10DE, .model_id = 0x137B, .preset_level = .very_low}, //NVIDIA; Quadro M520
.{ .vendor_id = 0x10DE, .model_id = 0x1380, .preset_level = .low }, //NVIDIA; GeForce GTX 750 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1381, .preset_level = .very_low}, //NVIDIA; GeForce GTX 750
.{ .vendor_id = 0x10DE, .model_id = 0x1382, .preset_level = .low }, //NVIDIA; GeForce GTX 745
.{ .vendor_id = 0x10DE, .model_id = 0x1391, .preset_level = .very_low}, //NVIDIA; GeForce GTX 850M
.{ .vendor_id = 0x10DE, .model_id = 0x1392, .preset_level = .very_low}, //NVIDIA; GeForce GPU
.{ .vendor_id = 0x10DE, .model_id = 0x139A, .preset_level = .very_low}, //NVIDIA; GeForce GTX 950M
.{ .vendor_id = 0x10DE, .model_id = 0x139B, .preset_level = .very_low}, //NVIDIA; GeForce GTX 960M
.{ .vendor_id = 0x10DE, .model_id = 0x139C, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce 940M
.{ .vendor_id = 0x10DE, .model_id = 0x13B0, .preset_level = .very_low}, //NVIDIA; Quadro M2000M
.{ .vendor_id = 0x10DE, .model_id = 0x13B1, .preset_level = .very_low}, //NVIDIA; M1000M
.{ .vendor_id = 0x10DE, .model_id = 0x13B4, .preset_level = .very_low}, //NVIDIA; Quadro M620
.{ .vendor_id = 0x10DE, .model_id = 0x13B6, .preset_level = .very_low}, //NVIDIA; Quadro M1200
.{ .vendor_id = 0x10DE, .model_id = 0x13BA, .preset_level = .very_low}, //NVIDIA; K2200
.{ .vendor_id = 0x10DE, .model_id = 0x13BB, .preset_level = .very_low}, //NVIDIA; Quadro K620
.{ .vendor_id = 0x10DE, .model_id = 0x13C0, .preset_level = .medium}, //NVIDIA; GeForce GTX 980
.{ .vendor_id = 0x10DE, .model_id = 0x13C2, .preset_level = .medium}, //NVIDIA; GeForce GTX 970
.{ .vendor_id = 0x10DE, .model_id = 0x13D7, .preset_level = .low }, //NVIDIA; GeForce GTX 980M
.{ .vendor_id = 0x10DE, .model_id = 0x13D8, .preset_level = .low }, //NVIDIA; GeForce GTX 970M
.{ .vendor_id = 0x10DE, .model_id = 0x13F1, .preset_level = .low }, //NVIDIA; Quadro M4000
.{ .vendor_id = 0x10DE, .model_id = 0x13F2, .preset_level = .low }, //NVIDIA; GRID M60-8Q
.{ .vendor_id = 0x10DE, .model_id = 0x13F8, .preset_level = .low }, //NVIDIA; Quadro M5000M
.{ .vendor_id = 0x10DE, .model_id = 0x13F9, .preset_level = .low }, //NVIDIA; Quadro M4000M
.{ .vendor_id = 0x10DE, .model_id = 0x13FA, .preset_level = .low }, //NVIDIA; Quadro M3000M
.{ .vendor_id = 0x10DE, .model_id = 0x1401, .preset_level = .low }, //NVIDIA; GeForce GTX 960
.{ .vendor_id = 0x10DE, .model_id = 0x1402, .preset_level = .low }, //NVIDIA; GeForce GTX 950
.{ .vendor_id = 0x10DE, .model_id = 0x1407, .preset_level = .very_low}, //NVIDIA; GeForce GTX 750
.{ .vendor_id = 0x10DE, .model_id = 0x1427, .preset_level = .very_low}, //NVIDIA; GeForce GTX 965M
.{ .vendor_id = 0x10DE, .model_id = 0x1430, .preset_level = .low }, //NVIDIA; Quadro M2000
.{ .vendor_id = 0x10DE, .model_id = 0x1436, .preset_level = .low }, //NVIDIA; Quadro M2200
.{ .vendor_id = 0x10DE, .model_id = 0x15F0, .preset_level = .high}, //NVIDIA; Quadro GP100
.{ .vendor_id = 0x10DE, .model_id = 0x1617, .preset_level = .low }, //NVIDIA; NVIDIA GeForce GTX 980M
.{ .vendor_id = 0x10DE, .model_id = 0x1618, .preset_level = .low }, //NVIDIA; GeForce GTX 970M
.{ .vendor_id = 0x10DE, .model_id = 0x174D, .preset_level = .very_low}, //NVIDIA; GeForce MX130
.{ .vendor_id = 0x10DE, .model_id = 0x174E, .preset_level = .very_low}, //NVIDIA; GeForce MX110
.{ .vendor_id = 0x10DE, .model_id = 0x179C, .preset_level = .very_low}, //NVIDIA; 940MX
.{ .vendor_id = 0x10DE, .model_id = 0x17C2, .preset_level = .medium}, //NVIDIA; GeForce GTX TITAN X
.{ .vendor_id = 0x10DE, .model_id = 0x17C8, .preset_level = .medium}, //NVIDIA; GeForce GTX 980 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x17F0, .preset_level = .medium}, //NVIDIA; Quadro M6000
.{ .vendor_id = 0x10DE, .model_id = 0x17F1, .preset_level = .medium}, //NVIDIA; Quadro M6000 24GB
.{ .vendor_id = 0x10DE, .model_id = 0x1B00, .preset_level = .medium}, //NVIDIA; NVIDIA TITAN X (Pascal)
.{ .vendor_id = 0x10DE, .model_id = 0x1B02, .preset_level = .high}, //NVIDIA; NVIDIA TITAN Xp
.{ .vendor_id = 0x10DE, .model_id = 0x1B06, .preset_level = .high}, //NVIDIA; GeForce GTX 1080 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1B30, .preset_level = .medium}, //NVIDIA; Quadro P6000
.{ .vendor_id = 0x10DE, .model_id = 0x1B38, .preset_level = .very_low}, //NVIDIA; GRID P40-4Q
.{ .vendor_id = 0x10DE, .model_id = 0x1B80, .preset_level = .high}, //NVIDIA; GeForce GTX 1080
.{ .vendor_id = 0x10DE, .model_id = 0x1B81, .preset_level = .medium}, //NVIDIA; GeForce GTX 1070
.{ .vendor_id = 0x10DE, .model_id = 0x1B82, .preset_level = .medium}, //NVIDIA; GeForce GTX 1070 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1B83, .preset_level = .medium}, //NVIDIA; GeForce GTX 1060 6GB
.{ .vendor_id = 0x10DE, .model_id = 0x1B84, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce GTX 1060 3GB
.{ .vendor_id = 0x10DE, .model_id = 0x1BA1, .preset_level = .low }, //NVIDIA; GeForce GTX 1070 with Max-Q Design
.{ .vendor_id = 0x10DE, .model_id = 0x1BB0, .preset_level = .medium}, //NVIDIA; Quadro P5000
.{ .vendor_id = 0x10DE, .model_id = 0x1BB1, .preset_level = .medium}, //NVIDIA; NVIDIA Quadro P4000
.{ .vendor_id = 0x10DE, .model_id = 0x1BB3, .preset_level = .medium}, //NVIDIA; Tesla P4
.{ .vendor_id = 0x10DE, .model_id = 0x1BB5, .preset_level = .medium}, //NVIDIA; Quadro P5200
.{ .vendor_id = 0x10DE, .model_id = 0x1BB6, .preset_level = .medium}, //NVIDIA; Quadro P5000
.{ .vendor_id = 0x10DE, .model_id = 0x1BB7, .preset_level = .medium}, //NVIDIA; NVIDIA Quadro P4000
.{ .vendor_id = 0x10DE, .model_id = 0x1BB8, .preset_level = .medium}, //NVIDIA; Quadro P3000
.{ .vendor_id = 0x10DE, .model_id = 0x1BB9, .preset_level = .medium}, //NVIDIA; Quadro P4200
.{ .vendor_id = 0x10DE, .model_id = 0x1BBB, .preset_level = .medium}, //NVIDIA; Quadro P3200
.{ .vendor_id = 0x10DE, .model_id = 0x1BE0, .preset_level = .high}, //NVIDIA; GeForce GTX 1080
.{ .vendor_id = 0x10DE, .model_id = 0x1BE1, .preset_level = .medium}, //NVIDIA; GeForce GTX 1070
.{ .vendor_id = 0x10DE, .model_id = 0x1C02, .preset_level = .medium}, //NVIDIA; GeForce GTX 1060 3GB
.{ .vendor_id = 0x10DE, .model_id = 0x1C03, .preset_level = .medium}, //NVIDIA; GeForce GTX 1060 6GB
.{ .vendor_id = 0x10DE, .model_id = 0x1C04, .preset_level = .medium}, //NVIDIA; GeForce GTX 1060 5GB
.{ .vendor_id = 0x10DE, .model_id = 0x1C06, .preset_level = .medium}, //NVIDIA; GeForce GTX 1060 6GB
.{ .vendor_id = 0x10DE, .model_id = 0x1C07, .preset_level = .low }, //NVIDIA; P106-100
.{ .vendor_id = 0x10DE, .model_id = 0x1C09, .preset_level = .very_low}, //NVIDIA; P106-090
.{ .vendor_id = 0x10DE, .model_id = 0x1C20, .preset_level = .medium}, //NVIDIA; GeForce GTX 1060
.{ .vendor_id = 0x10DE, .model_id = 0x1C21, .preset_level = .low }, //NVIDIA; GeForce GTX 1050 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1C30, .preset_level = .low }, //NVIDIA; Quadro P2000
.{ .vendor_id = 0x10DE, .model_id = 0x1C31, .preset_level = .medium}, //NVIDIA; Quadro P2200
.{ .vendor_id = 0x10DE, .model_id = 0x1C60, .preset_level = .medium}, //NVIDIA; GeForce GTX 1060
.{ .vendor_id = 0x10DE, .model_id = 0x1C81, .preset_level = .low }, //NVIDIA; GeForce GTX 1050
.{ .vendor_id = 0x10DE, .model_id = 0x1C82, .preset_level = .low }, //NVIDIA; GeForce GTX 1050 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1C8C, .preset_level = .low }, //NVIDIA; GeForce GTX 1050 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1C8D, .preset_level = .low }, //NVIDIA; GeForce GTX 1050
.{ .vendor_id = 0x10DE, .model_id = 0x1C8F, .preset_level = .low }, //NVIDIA; GeForce GTX 1050 Ti with Max-Q Design
.{ .vendor_id = 0x10DE, .model_id = 0x1C90, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce MX150
.{ .vendor_id = 0x10DE, .model_id = 0x1C91, .preset_level = .low }, //NVIDIA; GeForce GTX 1050
.{ .vendor_id = 0x10DE, .model_id = 0x1C92, .preset_level = .low }, //NVIDIA; GeForce GTX 1050
.{ .vendor_id = 0x10DE, .model_id = 0x1C94, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce MX350
.{ .vendor_id = 0x10DE, .model_id = 0x1C96, .preset_level = .very_low}, //NVIDIA; GeForce MX350
.{ .vendor_id = 0x10DE, .model_id = 0x1CB2, .preset_level = .very_low}, //NVIDIA; Quadro P600
.{ .vendor_id = 0x10DE, .model_id = 0x1CB3, .preset_level = .very_low}, //NVIDIA; Quadro P400
.{ .vendor_id = 0x10DE, .model_id = 0x1CB6, .preset_level = .very_low}, //NVIDIA; Quadro P620
.{ .vendor_id = 0x10DE, .model_id = 0x1CBA, .preset_level = .low }, //NVIDIA; Quadro P2000
.{ .vendor_id = 0x10DE, .model_id = 0x1CBB, .preset_level = .low }, //NVIDIA; Quadro P1000
.{ .vendor_id = 0x10DE, .model_id = 0x1CBC, .preset_level = .very_low}, //NVIDIA; Quadro P600
.{ .vendor_id = 0x10DE, .model_id = 0x1CBD, .preset_level = .very_low}, //NVIDIA; NVIDIA Quadro P620
.{ .vendor_id = 0x10DE, .model_id = 0x1D01, .preset_level = .very_low}, //NVIDIA; GeForce GT 1030
.{ .vendor_id = 0x10DE, .model_id = 0x1D10, .preset_level = .very_low}, //NVIDIA; GeForce MX150
.{ .vendor_id = 0x10DE, .model_id = 0x1D11, .preset_level = .very_low}, //NVIDIA; GeForce MX230
.{ .vendor_id = 0x10DE, .model_id = 0x1D12, .preset_level = .very_low}, //NVIDIA; GeForce MX150
.{ .vendor_id = 0x10DE, .model_id = 0x1D13, .preset_level = .very_low}, //NVIDIA; GeForce MX250
.{ .vendor_id = 0x10DE, .model_id = 0x1D16, .preset_level = .very_low}, //NVIDIA; GeForce MX330
.{ .vendor_id = 0x10DE, .model_id = 0x1D52, .preset_level = .very_low}, //NVIDIA; GeForce MX250
.{ .vendor_id = 0x10DE, .model_id = 0x1D81, .preset_level = .high}, //NVIDIA; NVIDIA TITAN V
.{ .vendor_id = 0x10DE, .model_id = 0x1DBA, .preset_level = .high}, //NVIDIA; Quadro GV100
.{ .vendor_id = 0x10DE, .model_id = 0x1E02, .preset_level = .high}, //NVIDIA; NVIDIA TITAN RTX
.{ .vendor_id = 0x10DE, .model_id = 0x1E04, .preset_level = .high}, //NVIDIA; GeForce RTX 2080 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1E07, .preset_level = .high}, //NVIDIA; GeForce RTX 2080 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1E30, .preset_level = .high}, //NVIDIA; Quadro RTX 6000
.{ .vendor_id = 0x10DE, .model_id = 0x1E81, .preset_level = .high}, //NVIDIA; GeForce RTX 2080 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x1E82, .preset_level = .high}, //NVIDIA; GeForce RTX 2080
.{ .vendor_id = 0x10DE, .model_id = 0x1E84, .preset_level = .high}, //NVIDIA; GeForce RTX 2070 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x1E87, .preset_level = .high}, //NVIDIA; GeForce RTX 2080
.{ .vendor_id = 0x10DE, .model_id = 0x1E89, .preset_level = .medium}, //NVIDIA; GeForce RTX 2060
.{ .vendor_id = 0x10DE, .model_id = 0x1E90, .preset_level = .medium}, //NVIDIA; GeForce RTX 2080 with Max-Q Design
.{ .vendor_id = 0x10DE, .model_id = 0x1E91, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2070 Super
.{ .vendor_id = 0x10DE, .model_id = 0x1E93, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 2080 Super with Max-Q Design
.{ .vendor_id = 0x10DE, .model_id = 0x1EB0, .preset_level = .high}, //NVIDIA; Quadro RTX 5000
.{ .vendor_id = 0x10DE, .model_id = 0x1EB1, .preset_level = .medium}, //NVIDIA; Quadro RTX 4000
.{ .vendor_id = 0x10DE, .model_id = 0x1EB5, .preset_level = .medium}, //NVIDIA; NVIDIA Quadro RTX 5000 with Max-Q Design
.{ .vendor_id = 0x10DE, .model_id = 0x1EB6, .preset_level = .medium}, //NVIDIA; Quadro RTX 4000
.{ .vendor_id = 0x10DE, .model_id = 0x1EB8, .preset_level = .low }, //NVIDIA; GRID T4-2B
.{ .vendor_id = 0x10DE, .model_id = 0x1EC7, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2070 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x1ED0, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2080
.{ .vendor_id = 0x10DE, .model_id = 0x1ED1, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2070 Super
.{ .vendor_id = 0x10DE, .model_id = 0x1ED3, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 2080 Super with Max-Q Design
.{ .vendor_id = 0x10DE, .model_id = 0x1F02, .preset_level = .high}, //NVIDIA; GeForce RTX 2070
.{ .vendor_id = 0x10DE, .model_id = 0x1F03, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 2060
.{ .vendor_id = 0x10DE, .model_id = 0x1F06, .preset_level = .high}, //NVIDIA; GeForce RTX 2060 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x1F07, .preset_level = .high}, //NVIDIA; GeForce RTX 2070
.{ .vendor_id = 0x10DE, .model_id = 0x1F08, .preset_level = .medium}, //NVIDIA; GeForce RTX 2060
.{ .vendor_id = 0x10DE, .model_id = 0x1F0A, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x1F10, .preset_level = .high}, //NVIDIA; GeForce RTX 2070
.{ .vendor_id = 0x10DE, .model_id = 0x1F11, .preset_level = .medium}, //NVIDIA; GeForce RTX 2060
.{ .vendor_id = 0x10DE, .model_id = 0x1F12, .preset_level = .medium}, //NVIDIA; GeForce RTX 2060 with Max-Q Design
.{ .vendor_id = 0x10DE, .model_id = 0x1F14, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2070
.{ .vendor_id = 0x10DE, .model_id = 0x1F15, .preset_level = .medium}, //NVIDIA; GeForce RTX 2060
.{ .vendor_id = 0x10DE, .model_id = 0x1F36, .preset_level = .medium}, //NVIDIA; Quadro RTX 3000
.{ .vendor_id = 0x10DE, .model_id = 0x1F47, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2060 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x1F50, .preset_level = .high}, //NVIDIA; GeForce RTX 2070
.{ .vendor_id = 0x10DE, .model_id = 0x1F82, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x1F91, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x1F95, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x1F96, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x1F97, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce MX450
.{ .vendor_id = 0x10DE, .model_id = 0x1F99, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x1F9C, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce MX450
.{ .vendor_id = 0x10DE, .model_id = 0x1F9D, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x1F9F, .preset_level = .low }, //NVIDIA; NVIDIA GeForce MX550
.{ .vendor_id = 0x10DE, .model_id = 0x1FB1, .preset_level = .low }, //NVIDIA; NVIDIA T600
.{ .vendor_id = 0x10DE, .model_id = 0x1FB2, .preset_level = .very_low}, //NVIDIA; NVIDIA T400
.{ .vendor_id = 0x10DE, .model_id = 0x1FB6, .preset_level = .very_low}, //NVIDIA; NVIDIA T600 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x1FB7, .preset_level = .low }, //NVIDIA; NVIDIA T550 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x1FB8, .preset_level = .low }, //NVIDIA; NVIDIA Quadro T2000
.{ .vendor_id = 0x10DE, .model_id = 0x1FB9, .preset_level = .low }, //NVIDIA; Quadro T1000
.{ .vendor_id = 0x10DE, .model_id = 0x1FBA, .preset_level = .very_low}, //NVIDIA; NVIDIA T600 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x1FBB, .preset_level = .very_low}, //NVIDIA; NVIDIA T500
.{ .vendor_id = 0x10DE, .model_id = 0x1FBC, .preset_level = .low }, //NVIDIA; NVIDIA T1200 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x1FDD, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x1FF2, .preset_level = .very_low}, //NVIDIA; NVIDIA T400 4GB
.{ .vendor_id = 0x10DE, .model_id = 0x2182, .preset_level = .medium}, //NVIDIA; GeForce GTX 1660 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2184, .preset_level = .medium}, //NVIDIA; GeForce GTX 1660
.{ .vendor_id = 0x10DE, .model_id = 0x2187, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x2188, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce GTX 1650
.{ .vendor_id = 0x10DE, .model_id = 0x2191, .preset_level = .medium}, //NVIDIA; GeForce GTX 1660 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2192, .preset_level = .medium}, //NVIDIA; GeForce GTX 1650 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x21C4, .preset_level = .medium}, //NVIDIA; GeForce GTX 1660 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x2203, .preset_level = .ultra}, //NVIDIA; NVIDIA GeForce RTX 3090 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2204, .preset_level = .high}, //NVIDIA; GeForce RTX 3090
.{ .vendor_id = 0x10DE, .model_id = 0x2206, .preset_level = .high}, //NVIDIA; GeForce RTX 3080
.{ .vendor_id = 0x10DE, .model_id = 0x2207, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3070 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2208, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3080 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x220A, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3080
.{ .vendor_id = 0x10DE, .model_id = 0x2216, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3080
.{ .vendor_id = 0x10DE, .model_id = 0x2230, .preset_level = .high}, //NVIDIA; NVIDIA RTX A6000
.{ .vendor_id = 0x10DE, .model_id = 0x2231, .preset_level = .high}, //NVIDIA; NVIDIA RTX A5000
.{ .vendor_id = 0x10DE, .model_id = 0x2232, .preset_level = .high}, //NVIDIA; NVIDIA RTX A4500
.{ .vendor_id = 0x10DE, .model_id = 0x2237, .preset_level = .high}, //NVIDIA; NVIDIA A10G
.{ .vendor_id = 0x10DE, .model_id = 0x2420, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3080 Ti Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2438, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A5500 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2460, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3080 Ti Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2482, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3070 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2484, .preset_level = .high}, //NVIDIA; GeForce RTX 3070
.{ .vendor_id = 0x10DE, .model_id = 0x2486, .preset_level = .high}, //NVIDIA; GeForce RTX 3060 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2487, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3060
.{ .vendor_id = 0x10DE, .model_id = 0x2488, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3070
.{ .vendor_id = 0x10DE, .model_id = 0x2489, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3060 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x249C, .preset_level = .high}, //NVIDIA; GeForce RTX 3080 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x249D, .preset_level = .medium}, //NVIDIA; GeForce RTX 3070 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x24A0, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3070 Ti Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x24B0, .preset_level = .high}, //NVIDIA; NVIDIA RTX A4000
.{ .vendor_id = 0x10DE, .model_id = 0x24B6, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A5000 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x24B8, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A3000 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x24B9, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A3000 12GB Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x24C9, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3060 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x24DC, .preset_level = .high}, //NVIDIA; GeForce RTX 3080 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x24DD, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3070 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x24E0, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3070 Ti Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2503, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3060
.{ .vendor_id = 0x10DE, .model_id = 0x2504, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3060
.{ .vendor_id = 0x10DE, .model_id = 0x2507, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3050
.{ .vendor_id = 0x10DE, .model_id = 0x2508, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3050 OEM
.{ .vendor_id = 0x10DE, .model_id = 0x2520, .preset_level = .medium}, //NVIDIA; GeForce RTX 3060 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2531, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A2000
.{ .vendor_id = 0x10DE, .model_id = 0x2544, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3060
.{ .vendor_id = 0x10DE, .model_id = 0x2560, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3060 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2563, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3050 Ti Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2571, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A2000 12GB
.{ .vendor_id = 0x10DE, .model_id = 0x2582, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3050
.{ .vendor_id = 0x10DE, .model_id = 0x25A0, .preset_level = .medium}, //NVIDIA; GeForce RTX 3050 Ti Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25A2, .preset_level = .medium}, //NVIDIA; GeForce RTX 3050 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25A5, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3050 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25A9, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2050
.{ .vendor_id = 0x10DE, .model_id = 0x25AA, .preset_level = .low }, //NVIDIA; NVIDIA GeForce MX570 A
.{ .vendor_id = 0x10DE, .model_id = 0x25AC, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 3050 6GB Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25AD, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 2050
.{ .vendor_id = 0x10DE, .model_id = 0x25B8, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A2000 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25B9, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A1000 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25BA, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A2000 8GB Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25BB, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A500 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25BC, .preset_level = .medium}, //NVIDIA; NVIDIA RTX A1000 6GB Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25E0, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3050 Ti Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25E2, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3050 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x25EC, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 3050 6GB Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2684, .preset_level = .ultra}, //NVIDIA; NVIDIA GeForce RTX 4090
.{ .vendor_id = 0x10DE, .model_id = 0x2702, .preset_level = .ultra}, //NVIDIA; NVIDIA GeForce RTX 4080 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x2704, .preset_level = .ultra}, //NVIDIA; NVIDIA GeForce RTX 4080
.{ .vendor_id = 0x10DE, .model_id = 0x2705, .preset_level = .ultra}, //NVIDIA; NVIDIA GeForce RTX 4070 Ti SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x2730, .preset_level = .high}, //NVIDIA; NVIDIA RTX 5000 Ada Generation Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2757, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4090 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2782, .preset_level = .ultra}, //NVIDIA; NVIDIA GeForce RTX 4070 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2783, .preset_level = .ultra}, //NVIDIA; NVIDIA GeForce RTX 4070 SUPER
.{ .vendor_id = 0x10DE, .model_id = 0x2786, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4070
.{ .vendor_id = 0x10DE, .model_id = 0x27A0, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4080 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x27BB, .preset_level = .high}, //NVIDIA; NVIDIA RTX 3500 Ada Generation Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x27E0, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4080 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2803, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4060 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2805, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4060 Ti
.{ .vendor_id = 0x10DE, .model_id = 0x2820, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4070 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2860, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4070 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x2882, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4060
.{ .vendor_id = 0x10DE, .model_id = 0x28A0, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4060 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x28A1, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 4050 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x28E0, .preset_level = .high}, //NVIDIA; NVIDIA GeForce RTX 4060 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x28E1, .preset_level = .medium}, //NVIDIA; NVIDIA GeForce RTX 4050 Laptop GPU
.{ .vendor_id = 0x10DE, .model_id = 0x67DF, .preset_level = .very_low}, //NVIDIA; NVIDIA GeForce GTX 765M
.{ .vendor_id = 0x10DE, .model_id = 0xFC0, .preset_level = .very_low}, //NVIDIA; GeForce GT 640
.{ .vendor_id = 0x10DE, .model_id = 0xFC1, .preset_level = .very_low}, //NVIDIA; GeForce GT 640
.{ .vendor_id = 0x10DE, .model_id = 0xFC2, .preset_level = .very_low}, //NVIDIA; GeForce GT 630
.{ .vendor_id = 0x10DE, .model_id = 0xFC6, .preset_level = .very_low}, //NVIDIA; GeForce GT 740
.{ .vendor_id = 0x10DE, .model_id = 0xFC8, .preset_level = .very_low}, //NVIDIA; GeForce GT 740
.{ .vendor_id = 0x10DE, .model_id = 0xFCD, .preset_level = .very_low}, //NVIDIA; GeForce GT 755M
.{ .vendor_id = 0x10DE, .model_id = 0xFD1, .preset_level = .very_low}, //NVIDIA; GeForce GT 650M
.{ .vendor_id = 0x10DE, .model_id = 0xFD2, .preset_level = .very_low}, //NVIDIA; GeForce GT 640M
.{ .vendor_id = 0x10DE, .model_id = 0xFD3, .preset_level = .very_low}, //NVIDIA; GeForce GT 640M LE
.{ .vendor_id = 0x10DE, .model_id = 0xFD4, .preset_level = .very_low}, //NVIDIA; GeForce GTX 660M
.{ .vendor_id = 0x10DE, .model_id = 0xFD9, .preset_level = .very_low}, //NVIDIA; GeForce GT 645M
.{ .vendor_id = 0x10DE, .model_id = 0xFDF, .preset_level = .very_low}, //NVIDIA; GeForce GT 740M
.{ .vendor_id = 0x10DE, .model_id = 0xFE1, .preset_level = .very_low}, //NVIDIA; GeForce GT 730M
.{ .vendor_id = 0x10DE, .model_id = 0xFE3, .preset_level = .very_low}, //NVIDIA; GeForce GT 745M
.{ .vendor_id = 0x10DE, .model_id = 0xFE4, .preset_level = .very_low}, //NVIDIA; GeForce GT 750M
.{ .vendor_id = 0x10DE, .model_id = 0xFE9, .preset_level = .very_low}, //NVIDIA; GeForce GT 750M
.{ .vendor_id = 0x10DE, .model_id = 0xFF3, .preset_level = .very_low}, //NVIDIA; Quadro K420
.{ .vendor_id = 0x10DE, .model_id = 0xFF6, .preset_level = .very_low}, //NVIDIA; Quadro K1100M
.{ .vendor_id = 0x10DE, .model_id = 0xFFA, .preset_level = .very_low}, //NVIDIA; Quadro K600
.{ .vendor_id = 0x10DE, .model_id = 0xFFB, .preset_level = .very_low}, //NVIDIA; Quadro K2000M
.{ .vendor_id = 0x10DE, .model_id = 0xFFC, .preset_level = .very_low}, //NVIDIA; Quadro K1000M
.{ .vendor_id = 0x10DE, .model_id = 0xFFE, .preset_level = .very_low}, //NVIDIA; K2000
.{ .vendor_id = 0x10DE, .model_id = 0xFFF, .preset_level = .very_low}, //NVIDIA; NVIDIA Quadro 410

// #qualcomm
.{.vendor_id = 0x5143, .model_id = 0x6030500, .preset_level = .none}, //Qualcomm; Adreno 7c+ Gen 3
.{.vendor_id = 0x5143, .model_id = 0x6080001, .preset_level = .none}, //Qualcomm; Qualcomm(R) Adreno(TM) 640 GPU
.{.vendor_id = 0x5143, .model_id = 0x6090000, .preset_level = .none}, //Qualcomm; Adreno (TM) 690
.{.vendor_id = 0x5143, .model_id = 0x7030002, .preset_level = .none} //Qualcomm; Turnip Adreno (TM) 725
};
