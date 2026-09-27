<#
    Console.psm1: the Pwsh console core in PowerShell, ported from the
    TypeScript reference built to docs/console-reference.md (commit
    e5426ffec4267ef91a63cf9d0b623589b041dd2f) and checked with its 63
    conformance vectors (tools/Test-ConsoleVectors.ps1).

    Cells are three int words (the contract's layout; every field fits in
    31 bits). A frame is an int[] of cols * rows * 3 words.

    This is the control-plane reference. The frame ring here keeps the
    contract's protocol over unmanaged memory with plain aligned reads and
    writes; cross-thread and cross-process ordering (Atomics in the
    contract) is a requirement on the lowered implementation, which can use
    Volatile and Interlocked on pointers.

    Language and .NET only: no cmdlet module is needed, so it runs in the
    Pwsh app's payload.
#>

Set-StrictMode -Version 3.0

# --- Cells and palette ---------------------------------------------------------

class ConsoleStyle {
    [int] $Fg = 0; [int] $FgMode = 0; [int] $Bg = 0; [int] $BgMode = 0; [int] $Attrs = 0
    ConsoleStyle() { }
    ConsoleStyle([int] $fg, [int] $fgMode, [int] $bg, [int] $bgMode, [int] $attrs) {
        $this.Fg = $fg; $this.FgMode = $fgMode; $this.Bg = $bg; $this.BgMode = $bgMode; $this.Attrs = $attrs
    }
    [ConsoleStyle] Clone() { return [ConsoleStyle]::new($this.Fg, $this.FgMode, $this.Bg, $this.BgMode, $this.Attrs) }
}

class ConsoleCells {
    static [int] $Words = 3
    static [int[]] $Palette = [ConsoleCells]::BuildPalette()

    static [int[]] BuildPalette() {
        $t = [int[]]::new(256)
        $ansi = @(0x0c0c0c, 0xc50f1f, 0x13a10e, 0xc19c00, 0x0037da, 0x881798, 0x3a96dd, 0xcccccc,
                  0x767676, 0xe74856, 0x16c60c, 0xf9f1a5, 0x3b78ff, 0xb4009e, 0x61d6d6, 0xf2f2f2)
        for ($i = 0; $i -lt 16; $i++) { $t[$i] = $ansi[$i] }
        $levels = @(0, 95, 135, 175, 215, 255)
        for ($r = 0; $r -lt 6; $r++) { for ($g = 0; $g -lt 6; $g++) { for ($b = 0; $b -lt 6; $b++) {
            $t[16 + 36 * $r + 6 * $g + $b] = ($levels[$r] -shl 16) -bor ($levels[$g] -shl 8) -bor $levels[$b]
        } } }
        for ($k = 0; $k -lt 24; $k++) { $v = 8 + 10 * $k; $t[232 + $k] = ($v -shl 16) -bor ($v -shl 8) -bor $v }
        return $t
    }

    # System.ConsoleColor value to palette index (the contract's mapping).
    static [int[]] $ConsoleColorToPalette = @(0, 4, 2, 6, 1, 5, 3, 7, 8, 12, 10, 14, 9, 13, 11, 15)

    static [int] Word0([int] $scalar, [int] $width, [int] $attrs) {
        return ($scalar -band 0x1fffff) -bor (($width -band 3) -shl 21) -bor (($attrs -band 0x3f) -shl 23)
    }
    static [int] ColorWord([int] $value, [int] $mode) {
        $v = if ($mode -eq 1) { $value -band 0xff } else { $value -band 0xffffff }
        return $v -bor (($mode -band 3) -shl 24)
    }
    static [void] Put([int[]] $frame, [int] $index, [int] $scalar, [int] $width, [ConsoleStyle] $s) {
        $b = $index * 3
        $frame[$b] = [ConsoleCells]::Word0($scalar, $width, $s.Attrs)
        $frame[$b + 1] = [ConsoleCells]::ColorWord($s.Fg, $s.FgMode)
        $frame[$b + 2] = [ConsoleCells]::ColorWord($s.Bg, $s.BgMode)
    }
    static [int] Resolve([int] $value, [int] $mode, [bool] $isForeground) {
        if ($mode -eq 0) { if ($isForeground) { return 0xcccccc } else { return 0x0c0c0c } }
        if ($mode -eq 1) { return [ConsoleCells]::Palette[$value -band 0xff] }
        return $value -band 0xffffff
    }
}

# --- Widths --------------------------------------------------------------------

class ConsoleWidth {
    # region generated width tables (tools/Update-ConsoleWidthTable.ps1; do not edit)
    # EastAsianWidth.txt 16.0.0 SHA-256 43ADC76C0686A42CB370764EB8CFE2B2A45B10B855E5572A2DB4A0EECCE15D5B: 122 wide ranges.
    # UnicodeData.txt 16.0.0 SHA-256 FF58E5823BD095166564A006E47D111130813DCF8BF234EF79FA51A870EDB48F: 368 zero-width ranges.
    static [int[]] $Wide = @(
        0x1100,0x115F, 0x231A,0x231B, 0x2329,0x232A, 0x23E9,0x23EC, 0x23F0,0x23F0, 0x23F3,0x23F3, 0x25FD,0x25FE, 0x2614,0x2615,
        0x2630,0x2637, 0x2648,0x2653, 0x267F,0x267F, 0x268A,0x268F, 0x2693,0x2693, 0x26A1,0x26A1, 0x26AA,0x26AB, 0x26BD,0x26BE,
        0x26C4,0x26C5, 0x26CE,0x26CE, 0x26D4,0x26D4, 0x26EA,0x26EA, 0x26F2,0x26F3, 0x26F5,0x26F5, 0x26FA,0x26FA, 0x26FD,0x26FD,
        0x2705,0x2705, 0x270A,0x270B, 0x2728,0x2728, 0x274C,0x274C, 0x274E,0x274E, 0x2753,0x2755, 0x2757,0x2757, 0x2795,0x2797,
        0x27B0,0x27B0, 0x27BF,0x27BF, 0x2B1B,0x2B1C, 0x2B50,0x2B50, 0x2B55,0x2B55, 0x2E80,0x2E99, 0x2E9B,0x2EF3, 0x2F00,0x2FD5,
        0x2FF0,0x303E, 0x3041,0x3096, 0x3099,0x30FF, 0x3105,0x312F, 0x3131,0x318E, 0x3190,0x31E5, 0x31EF,0x321E, 0x3220,0x3247,
        0x3250,0xA48C, 0xA490,0xA4C6, 0xA960,0xA97C, 0xAC00,0xD7A3, 0xF900,0xFAFF, 0xFE10,0xFE19, 0xFE30,0xFE52, 0xFE54,0xFE66,
        0xFE68,0xFE6B, 0xFF01,0xFF60, 0xFFE0,0xFFE6, 0x16FE0,0x16FE4, 0x16FF0,0x16FF1, 0x17000,0x187F7, 0x18800,0x18CD5, 0x18CFF,0x18D08,
        0x1AFF0,0x1AFF3, 0x1AFF5,0x1AFFB, 0x1AFFD,0x1AFFE, 0x1B000,0x1B122, 0x1B132,0x1B132, 0x1B150,0x1B152, 0x1B155,0x1B155, 0x1B164,0x1B167,
        0x1B170,0x1B2FB, 0x1D300,0x1D356, 0x1D360,0x1D376, 0x1F004,0x1F004, 0x1F0CF,0x1F0CF, 0x1F18E,0x1F18E, 0x1F191,0x1F19A, 0x1F200,0x1F202,
        0x1F210,0x1F23B, 0x1F240,0x1F248, 0x1F250,0x1F251, 0x1F260,0x1F265, 0x1F300,0x1F320, 0x1F32D,0x1F335, 0x1F337,0x1F37C, 0x1F37E,0x1F393,
        0x1F3A0,0x1F3CA, 0x1F3CF,0x1F3D3, 0x1F3E0,0x1F3F0, 0x1F3F4,0x1F3F4, 0x1F3F8,0x1F43E, 0x1F440,0x1F440, 0x1F442,0x1F4FC, 0x1F4FF,0x1F53D,
        0x1F54B,0x1F54E, 0x1F550,0x1F567, 0x1F57A,0x1F57A, 0x1F595,0x1F596, 0x1F5A4,0x1F5A4, 0x1F5FB,0x1F64F, 0x1F680,0x1F6C5, 0x1F6CC,0x1F6CC,
        0x1F6D0,0x1F6D2, 0x1F6D5,0x1F6D7, 0x1F6DC,0x1F6DF, 0x1F6EB,0x1F6EC, 0x1F6F4,0x1F6FC, 0x1F7E0,0x1F7EB, 0x1F7F0,0x1F7F0, 0x1F90C,0x1F93A,
        0x1F93C,0x1F945, 0x1F947,0x1F9FF, 0x1FA70,0x1FA7C, 0x1FA80,0x1FA89, 0x1FA8F,0x1FAC6, 0x1FACE,0x1FADC, 0x1FADF,0x1FAE9, 0x1FAF0,0x1FAF8,
        0x20000,0x2FFFD, 0x30000,0x3FFFD)
    static [int[]] $Zero = @(
        0xAD,0xAD, 0x300,0x36F, 0x483,0x489, 0x591,0x5BD, 0x5BF,0x5BF, 0x5C1,0x5C2, 0x5C4,0x5C5, 0x5C7,0x5C7,
        0x600,0x605, 0x610,0x61A, 0x61C,0x61C, 0x64B,0x65F, 0x670,0x670, 0x6D6,0x6DD, 0x6DF,0x6E4, 0x6E7,0x6E8,
        0x6EA,0x6ED, 0x70F,0x70F, 0x711,0x711, 0x730,0x74A, 0x7A6,0x7B0, 0x7EB,0x7F3, 0x7FD,0x7FD, 0x816,0x819,
        0x81B,0x823, 0x825,0x827, 0x829,0x82D, 0x859,0x85B, 0x890,0x891, 0x897,0x89F, 0x8CA,0x902, 0x93A,0x93A,
        0x93C,0x93C, 0x941,0x948, 0x94D,0x94D, 0x951,0x957, 0x962,0x963, 0x981,0x981, 0x9BC,0x9BC, 0x9C1,0x9C4,
        0x9CD,0x9CD, 0x9E2,0x9E3, 0x9FE,0x9FE, 0xA01,0xA02, 0xA3C,0xA3C, 0xA41,0xA42, 0xA47,0xA48, 0xA4B,0xA4D,
        0xA51,0xA51, 0xA70,0xA71, 0xA75,0xA75, 0xA81,0xA82, 0xABC,0xABC, 0xAC1,0xAC5, 0xAC7,0xAC8, 0xACD,0xACD,
        0xAE2,0xAE3, 0xAFA,0xAFF, 0xB01,0xB01, 0xB3C,0xB3C, 0xB3F,0xB3F, 0xB41,0xB44, 0xB4D,0xB4D, 0xB55,0xB56,
        0xB62,0xB63, 0xB82,0xB82, 0xBC0,0xBC0, 0xBCD,0xBCD, 0xC00,0xC00, 0xC04,0xC04, 0xC3C,0xC3C, 0xC3E,0xC40,
        0xC46,0xC48, 0xC4A,0xC4D, 0xC55,0xC56, 0xC62,0xC63, 0xC81,0xC81, 0xCBC,0xCBC, 0xCBF,0xCBF, 0xCC6,0xCC6,
        0xCCC,0xCCD, 0xCE2,0xCE3, 0xD00,0xD01, 0xD3B,0xD3C, 0xD41,0xD44, 0xD4D,0xD4D, 0xD62,0xD63, 0xD81,0xD81,
        0xDCA,0xDCA, 0xDD2,0xDD4, 0xDD6,0xDD6, 0xE31,0xE31, 0xE34,0xE3A, 0xE47,0xE4E, 0xEB1,0xEB1, 0xEB4,0xEBC,
        0xEC8,0xECE, 0xF18,0xF19, 0xF35,0xF35, 0xF37,0xF37, 0xF39,0xF39, 0xF71,0xF7E, 0xF80,0xF84, 0xF86,0xF87,
        0xF8D,0xF97, 0xF99,0xFBC, 0xFC6,0xFC6, 0x102D,0x1030, 0x1032,0x1037, 0x1039,0x103A, 0x103D,0x103E, 0x1058,0x1059,
        0x105E,0x1060, 0x1071,0x1074, 0x1082,0x1082, 0x1085,0x1086, 0x108D,0x108D, 0x109D,0x109D, 0x135D,0x135F, 0x1712,0x1714,
        0x1732,0x1733, 0x1752,0x1753, 0x1772,0x1773, 0x17B4,0x17B5, 0x17B7,0x17BD, 0x17C6,0x17C6, 0x17C9,0x17D3, 0x17DD,0x17DD,
        0x180B,0x180F, 0x1885,0x1886, 0x18A9,0x18A9, 0x1920,0x1922, 0x1927,0x1928, 0x1932,0x1932, 0x1939,0x193B, 0x1A17,0x1A18,
        0x1A1B,0x1A1B, 0x1A56,0x1A56, 0x1A58,0x1A5E, 0x1A60,0x1A60, 0x1A62,0x1A62, 0x1A65,0x1A6C, 0x1A73,0x1A7C, 0x1A7F,0x1A7F,
        0x1AB0,0x1ACE, 0x1B00,0x1B03, 0x1B34,0x1B34, 0x1B36,0x1B3A, 0x1B3C,0x1B3C, 0x1B42,0x1B42, 0x1B6B,0x1B73, 0x1B80,0x1B81,
        0x1BA2,0x1BA5, 0x1BA8,0x1BA9, 0x1BAB,0x1BAD, 0x1BE6,0x1BE6, 0x1BE8,0x1BE9, 0x1BED,0x1BED, 0x1BEF,0x1BF1, 0x1C2C,0x1C33,
        0x1C36,0x1C37, 0x1CD0,0x1CD2, 0x1CD4,0x1CE0, 0x1CE2,0x1CE8, 0x1CED,0x1CED, 0x1CF4,0x1CF4, 0x1CF8,0x1CF9, 0x1DC0,0x1DFF,
        0x200B,0x200F, 0x202A,0x202E, 0x2060,0x2064, 0x2066,0x206F, 0x20D0,0x20F0, 0x2CEF,0x2CF1, 0x2D7F,0x2D7F, 0x2DE0,0x2DFF,
        0x302A,0x302D, 0x3099,0x309A, 0xA66F,0xA672, 0xA674,0xA67D, 0xA69E,0xA69F, 0xA6F0,0xA6F1, 0xA802,0xA802, 0xA806,0xA806,
        0xA80B,0xA80B, 0xA825,0xA826, 0xA82C,0xA82C, 0xA8C4,0xA8C5, 0xA8E0,0xA8F1, 0xA8FF,0xA8FF, 0xA926,0xA92D, 0xA947,0xA951,
        0xA980,0xA982, 0xA9B3,0xA9B3, 0xA9B6,0xA9B9, 0xA9BC,0xA9BD, 0xA9E5,0xA9E5, 0xAA29,0xAA2E, 0xAA31,0xAA32, 0xAA35,0xAA36,
        0xAA43,0xAA43, 0xAA4C,0xAA4C, 0xAA7C,0xAA7C, 0xAAB0,0xAAB0, 0xAAB2,0xAAB4, 0xAAB7,0xAAB8, 0xAABE,0xAABF, 0xAAC1,0xAAC1,
        0xAAEC,0xAAED, 0xAAF6,0xAAF6, 0xABE5,0xABE5, 0xABE8,0xABE8, 0xABED,0xABED, 0xFB1E,0xFB1E, 0xFE00,0xFE0F, 0xFE20,0xFE2F,
        0xFEFF,0xFEFF, 0xFFF9,0xFFFB, 0x101FD,0x101FD, 0x102E0,0x102E0, 0x10376,0x1037A, 0x10A01,0x10A03, 0x10A05,0x10A06, 0x10A0C,0x10A0F,
        0x10A38,0x10A3A, 0x10A3F,0x10A3F, 0x10AE5,0x10AE6, 0x10D24,0x10D27, 0x10D69,0x10D6D, 0x10EAB,0x10EAC, 0x10EFC,0x10EFF, 0x10F46,0x10F50,
        0x10F82,0x10F85, 0x11001,0x11001, 0x11038,0x11046, 0x11070,0x11070, 0x11073,0x11074, 0x1107F,0x11081, 0x110B3,0x110B6, 0x110B9,0x110BA,
        0x110BD,0x110BD, 0x110C2,0x110C2, 0x110CD,0x110CD, 0x11100,0x11102, 0x11127,0x1112B, 0x1112D,0x11134, 0x11173,0x11173, 0x11180,0x11181,
        0x111B6,0x111BE, 0x111C9,0x111CC, 0x111CF,0x111CF, 0x1122F,0x11231, 0x11234,0x11234, 0x11236,0x11237, 0x1123E,0x1123E, 0x11241,0x11241,
        0x112DF,0x112DF, 0x112E3,0x112EA, 0x11300,0x11301, 0x1133B,0x1133C, 0x11340,0x11340, 0x11366,0x1136C, 0x11370,0x11374, 0x113BB,0x113C0,
        0x113CE,0x113CE, 0x113D0,0x113D0, 0x113D2,0x113D2, 0x113E1,0x113E2, 0x11438,0x1143F, 0x11442,0x11444, 0x11446,0x11446, 0x1145E,0x1145E,
        0x114B3,0x114B8, 0x114BA,0x114BA, 0x114BF,0x114C0, 0x114C2,0x114C3, 0x115B2,0x115B5, 0x115BC,0x115BD, 0x115BF,0x115C0, 0x115DC,0x115DD,
        0x11633,0x1163A, 0x1163D,0x1163D, 0x1163F,0x11640, 0x116AB,0x116AB, 0x116AD,0x116AD, 0x116B0,0x116B5, 0x116B7,0x116B7, 0x1171D,0x1171D,
        0x1171F,0x1171F, 0x11722,0x11725, 0x11727,0x1172B, 0x1182F,0x11837, 0x11839,0x1183A, 0x1193B,0x1193C, 0x1193E,0x1193E, 0x11943,0x11943,
        0x119D4,0x119D7, 0x119DA,0x119DB, 0x119E0,0x119E0, 0x11A01,0x11A0A, 0x11A33,0x11A38, 0x11A3B,0x11A3E, 0x11A47,0x11A47, 0x11A51,0x11A56,
        0x11A59,0x11A5B, 0x11A8A,0x11A96, 0x11A98,0x11A99, 0x11C30,0x11C36, 0x11C38,0x11C3D, 0x11C3F,0x11C3F, 0x11C92,0x11CA7, 0x11CAA,0x11CB0,
        0x11CB2,0x11CB3, 0x11CB5,0x11CB6, 0x11D31,0x11D36, 0x11D3A,0x11D3A, 0x11D3C,0x11D3D, 0x11D3F,0x11D45, 0x11D47,0x11D47, 0x11D90,0x11D91,
        0x11D95,0x11D95, 0x11D97,0x11D97, 0x11EF3,0x11EF4, 0x11F00,0x11F01, 0x11F36,0x11F3A, 0x11F40,0x11F40, 0x11F42,0x11F42, 0x11F5A,0x11F5A,
        0x13430,0x13440, 0x13447,0x13455, 0x1611E,0x16129, 0x1612D,0x1612F, 0x16AF0,0x16AF4, 0x16B30,0x16B36, 0x16F4F,0x16F4F, 0x16F8F,0x16F92,
        0x16FE4,0x16FE4, 0x1BC9D,0x1BC9E, 0x1BCA0,0x1BCA3, 0x1CF00,0x1CF2D, 0x1CF30,0x1CF46, 0x1D167,0x1D169, 0x1D173,0x1D182, 0x1D185,0x1D18B,
        0x1D1AA,0x1D1AD, 0x1D242,0x1D244, 0x1DA00,0x1DA36, 0x1DA3B,0x1DA6C, 0x1DA75,0x1DA75, 0x1DA84,0x1DA84, 0x1DA9B,0x1DA9F, 0x1DAA1,0x1DAAF,
        0x1E000,0x1E006, 0x1E008,0x1E018, 0x1E01B,0x1E021, 0x1E023,0x1E024, 0x1E026,0x1E02A, 0x1E08F,0x1E08F, 0x1E130,0x1E136, 0x1E2AE,0x1E2AE,
        0x1E2EC,0x1E2EF, 0x1E4EC,0x1E4EF, 0x1E5EE,0x1E5EF, 0x1E8D0,0x1E8D6, 0x1E944,0x1E94A, 0xE0001,0xE0001, 0xE0020,0xE007F, 0xE0100,0xE01EF)
    # endregion generated width tables

    # Flattened [start, end, start, end, ...] ranges, binary searched.
    static [bool] InRanges([int] $scalar, [int[]] $ranges) {
        $lo = 0; $hi = ($ranges.Length -shr 1) - 1
        while ($lo -le $hi) {
            $mid = ($lo + $hi) -shr 1
            if ($scalar -lt $ranges[2 * $mid]) { $hi = $mid - 1 }
            elseif ($scalar -gt $ranges[2 * $mid + 1]) { $lo = $mid + 1 }
            else { return $true }
        }
        return $false
    }
    # 2 for East_Asian_Width W or F; 0 for categories Mn, Me, Cf and U+200B; else 1.
    static [int] Of([int] $scalar) {
        if ([ConsoleWidth]::InRanges($scalar, [ConsoleWidth]::Zero)) { return 0 }
        if ([ConsoleWidth]::InRanges($scalar, [ConsoleWidth]::Wide)) { return 2 }
        return 1
    }
}

# --- Escape-sequence parser (vt100.net DEC ANSI parser) ---------------------------

class ConsoleAction {
    [string] $Kind          # print, execute, csi, esc, osc
    [int] $Code             # scalar for print, control code for execute
    [int[]] $Params = @()
    [string] $Intermediates = ''
    [string] $Final = ''
    [string] $Private = ''
    [string] $Data = ''
}

class ConsoleParser {
    # States: 0 Ground, 1 Escape, 2 EscapeIntermediate, 3 CsiEntry, 4 CsiParam,
    # 5 CsiIntermediate, 6 CsiIgnore, 7 DcsEntry, 8 DcsParam, 9 DcsIntermediate,
    # 10 DcsPassthrough, 11 DcsIgnore, 12 OscString, 13 SosPmApcString.
    hidden [int] $State = 0
    hidden [string] $Intermediates = ''
    hidden [System.Collections.Generic.List[int]] $Params = [System.Collections.Generic.List[int]]::new()
    hidden [string] $ParamText = ''
    hidden [string] $PrivateMarker = ''
    hidden [System.Text.StringBuilder] $Osc = [System.Text.StringBuilder]::new()

    hidden [void] Clear() { $this.Intermediates = ''; $this.Params.Clear(); $this.ParamText = ''; $this.PrivateMarker = '' }
    hidden [void] PushParam() {
        if ($this.ParamText.Length -eq 0) { $this.Params.Add(0) }
        else { $v = 0; if (-not [int]::TryParse($this.ParamText, [ref]$v)) { $v = 16383 }; $this.Params.Add([Math]::Min($v, 16383)) }
        $this.ParamText = ''
    }
    static [bool] IsC0([int] $c) { return ($c -le 0x17) -or $c -eq 0x19 -or ($c -ge 0x1c -and $c -le 0x1f) }
    static [ConsoleAction] Execute([int] $c) { $a = [ConsoleAction]::new(); $a.Kind = 'execute'; $a.Code = $c; return $a }
    hidden [ConsoleAction] Csi([int] $final) {
        $a = [ConsoleAction]::new(); $a.Kind = 'csi'; $a.Params = $this.Params.ToArray()
        $a.Intermediates = $this.Intermediates; $a.Final = [char]$final; $a.Private = $this.PrivateMarker
        return $a
    }

    # Feeds text and returns the actions, in order.
    [System.Collections.Generic.List[ConsoleAction]] Feed([string] $text) {
        $out = [System.Collections.Generic.List[ConsoleAction]]::new()
        foreach ($rune in $text.EnumerateRunes()) {
            $c = $rune.Value
            # Transitions from any state.
            if ($c -eq 0x18 -or $c -eq 0x1a) { $out.Add([ConsoleParser]::Execute($c)); $this.State = 0; continue }
            if ($c -eq 0x1b) { $this.Clear(); $this.State = 1; continue }
            if ($c -eq 0x9b) { $this.Clear(); $this.State = 3; continue }
            if ($c -eq 0x9d) { [void]$this.Osc.Clear(); $this.State = 12; continue }
            if ($c -eq 0x90) { $this.Clear(); $this.State = 7; continue }
            if ($c -eq 0x98 -or $c -eq 0x9e -or $c -eq 0x9f) { $this.State = 13; continue }
            if ($c -eq 0x9c) {
                if ($this.State -eq 12) { $a = [ConsoleAction]::new(); $a.Kind = 'osc'; $a.Data = $this.Osc.ToString(); $out.Add($a) }
                $this.State = 0; continue
            }
            if (($c -ge 0x80 -and $c -le 0x8f) -or ($c -ge 0x91 -and $c -le 0x97) -or $c -eq 0x99 -or $c -eq 0x9a) {
                $out.Add([ConsoleParser]::Execute($c)); $this.State = 0; continue
            }
            switch ($this.State) {
                0 {
                    if ([ConsoleParser]::IsC0($c)) { $out.Add([ConsoleParser]::Execute($c)) }
                    else { $a = [ConsoleAction]::new(); $a.Kind = 'print'; $a.Code = $c; $out.Add($a) }
                }
                1 {
                    if ([ConsoleParser]::IsC0($c)) { $out.Add([ConsoleParser]::Execute($c)) }
                    elseif ($c -eq 0x7f) { }
                    elseif ($c -ge 0x20 -and $c -le 0x2f) { $this.Intermediates += [char]$c; $this.State = 2 }
                    elseif ($c -eq 0x5b) { $this.Clear(); $this.State = 3 }
                    elseif ($c -eq 0x5d) { [void]$this.Osc.Clear(); $this.State = 12 }
                    elseif ($c -eq 0x50) { $this.Clear(); $this.State = 7 }
                    elseif ($c -eq 0x58 -or $c -eq 0x5e -or $c -eq 0x5f) { $this.State = 13 }
                    elseif ($c -eq 0x5c) { $this.State = 0 }
                    elseif ($c -ge 0x30 -and $c -le 0x7e) {
                        $a = [ConsoleAction]::new(); $a.Kind = 'esc'; $a.Intermediates = $this.Intermediates; $a.Final = [char]$c; $out.Add($a); $this.State = 0
                    }
                    else { $this.State = 0 }
                }
                2 {
                    if ([ConsoleParser]::IsC0($c)) { $out.Add([ConsoleParser]::Execute($c)) }
                    elseif ($c -eq 0x7f) { }
                    elseif ($c -ge 0x20 -and $c -le 0x2f) { $this.Intermediates += [char]$c }
                    elseif ($c -ge 0x30 -and $c -le 0x7e) {
                        $a = [ConsoleAction]::new(); $a.Kind = 'esc'; $a.Intermediates = $this.Intermediates; $a.Final = [char]$c; $out.Add($a); $this.State = 0
                    }
                    else { $this.State = 0 }
                }
                3 {
                    if ([ConsoleParser]::IsC0($c)) { $out.Add([ConsoleParser]::Execute($c)) }
                    elseif ($c -eq 0x7f) { }
                    elseif ($c -ge 0x30 -and $c -le 0x39) { $this.ParamText += [char]$c; $this.State = 4 }
                    elseif ($c -eq 0x3b) { $this.PushParam(); $this.State = 4 }
                    elseif ($c -ge 0x3c -and $c -le 0x3f) { $this.PrivateMarker = [char]$c; $this.State = 4 }
                    elseif ($c -eq 0x3a) { $this.State = 6 }
                    elseif ($c -ge 0x20 -and $c -le 0x2f) { $this.Intermediates += [char]$c; $this.State = 5 }
                    elseif ($c -ge 0x40 -and $c -le 0x7e) { $this.Params.Clear(); $out.Add($this.Csi($c)); $this.State = 0 }
                    else { $this.State = 0 }
                }
                4 {
                    if ([ConsoleParser]::IsC0($c)) { $out.Add([ConsoleParser]::Execute($c)) }
                    elseif ($c -eq 0x7f) { }
                    elseif ($c -ge 0x30 -and $c -le 0x39) { $this.ParamText += [char]$c }
                    elseif ($c -eq 0x3b) { $this.PushParam() }
                    elseif ($c -eq 0x3a -or ($c -ge 0x3c -and $c -le 0x3f)) { $this.State = 6 }
                    elseif ($c -ge 0x20 -and $c -le 0x2f) {
                        if ($this.ParamText.Length -gt 0 -or $this.Params.Count -gt 0) { $this.PushParam() }
                        $this.Intermediates += [char]$c; $this.State = 5
                    }
                    elseif ($c -ge 0x40 -and $c -le 0x7e) {
                        if ($this.ParamText.Length -gt 0 -or $this.Params.Count -gt 0) { $this.PushParam() }
                        $out.Add($this.Csi($c)); $this.State = 0
                    }
                    else { $this.State = 0 }
                }
                5 {
                    if ([ConsoleParser]::IsC0($c)) { $out.Add([ConsoleParser]::Execute($c)) }
                    elseif ($c -eq 0x7f) { }
                    elseif ($c -ge 0x20 -and $c -le 0x2f) { $this.Intermediates += [char]$c }
                    elseif ($c -ge 0x30 -and $c -le 0x3f) { $this.State = 6 }
                    elseif ($c -ge 0x40 -and $c -le 0x7e) { $out.Add($this.Csi($c)); $this.State = 0 }
                    else { $this.State = 0 }
                }
                6 {
                    if ([ConsoleParser]::IsC0($c)) { $out.Add([ConsoleParser]::Execute($c)) }
                    elseif ($c -ge 0x40 -and $c -le 0x7e) { $this.State = 0 }
                }
                7 {
                    if ($c -ge 0x30 -and $c -le 0x39) { $this.ParamText += [char]$c; $this.State = 8 }
                    elseif ($c -eq 0x3b) { $this.PushParam(); $this.State = 8 }
                    elseif ($c -ge 0x3c -and $c -le 0x3f) { $this.PrivateMarker = [char]$c; $this.State = 8 }
                    elseif ($c -eq 0x3a) { $this.State = 11 }
                    elseif ($c -ge 0x20 -and $c -le 0x2f) { $this.Intermediates += [char]$c; $this.State = 9 }
                    elseif ($c -ge 0x40 -and $c -le 0x7e) { $this.State = 10 }
                }
                8 {
                    if ($c -ge 0x30 -and $c -le 0x39) { $this.ParamText += [char]$c }
                    elseif ($c -eq 0x3b) { $this.PushParam() }
                    elseif ($c -eq 0x3a -or ($c -ge 0x3c -and $c -le 0x3f)) { $this.State = 11 }
                    elseif ($c -ge 0x20 -and $c -le 0x2f) { $this.Intermediates += [char]$c; $this.State = 9 }
                    elseif ($c -ge 0x40 -and $c -le 0x7e) { $this.State = 10 }
                }
                9 {
                    if ($c -ge 0x20 -and $c -le 0x2f) { $this.Intermediates += [char]$c }
                    elseif ($c -ge 0x30 -and $c -le 0x3f) { $this.State = 11 }
                    elseif ($c -ge 0x40 -and $c -le 0x7e) { $this.State = 10 }
                }
                12 {
                    if ($c -eq 0x07) { $a = [ConsoleAction]::new(); $a.Kind = 'osc'; $a.Data = $this.Osc.ToString(); $out.Add($a); $this.State = 0 }
                    elseif ($c -ge 0x20) { [void]$this.Osc.Append($rune.ToString()) }
                }
                # 10 DcsPassthrough, 11 DcsIgnore, 13 SosPmApcString: consumed until ST, ESC, CAN or SUB.
            }
        }
        return $out
    }
}

# --- SGR -----------------------------------------------------------------------

class ConsoleSgr {
    static [ConsoleStyle] Apply([ConsoleStyle] $style, [int[]] $params) {
        $s = $style.Clone()
        [int[]] $list = if ($params.Length -eq 0) { @(0) } else { $params }
        for ($i = 0; $i -lt $list.Length; $i++) {
            $p = $list[$i]
            if ($p -eq 0) { $s = [ConsoleStyle]::new() }
            elseif ($p -eq 1) { $s.Attrs = $s.Attrs -bor 1 }
            elseif ($p -eq 2) { $s.Attrs = $s.Attrs -bor 32 }
            elseif ($p -eq 3) { $s.Attrs = $s.Attrs -bor 2 }
            elseif ($p -eq 4) { $s.Attrs = $s.Attrs -bor 4 }
            elseif ($p -eq 7) { $s.Attrs = $s.Attrs -bor 8 }
            elseif ($p -eq 9) { $s.Attrs = $s.Attrs -bor 16 }
            elseif ($p -eq 22) { $s.Attrs = $s.Attrs -band (-bnot 33) }
            elseif ($p -eq 23) { $s.Attrs = $s.Attrs -band (-bnot 2) }
            elseif ($p -eq 24) { $s.Attrs = $s.Attrs -band (-bnot 4) }
            elseif ($p -eq 27) { $s.Attrs = $s.Attrs -band (-bnot 8) }
            elseif ($p -eq 29) { $s.Attrs = $s.Attrs -band (-bnot 16) }
            elseif ($p -ge 30 -and $p -le 37) { $s.FgMode = 1; $s.Fg = $p - 30 }
            elseif ($p -ge 90 -and $p -le 97) { $s.FgMode = 1; $s.Fg = $p - 90 + 8 }
            elseif ($p -eq 39) { $s.FgMode = 0; $s.Fg = 0 }
            elseif ($p -ge 40 -and $p -le 47) { $s.BgMode = 1; $s.Bg = $p - 40 }
            elseif ($p -ge 100 -and $p -le 107) { $s.BgMode = 1; $s.Bg = $p - 100 + 8 }
            elseif ($p -eq 49) { $s.BgMode = 0; $s.Bg = 0 }
            elseif ($p -eq 38 -or $p -eq 48) {
                $isFg = $p -eq 38
                $sub = if ($i + 1 -lt $list.Length) { $list[$i + 1] } else { -1 }
                if ($sub -eq 5 -and $i + 2 -lt $list.Length) {
                    $n = $list[$i + 2]
                    if ($n -ge 0 -and $n -le 255) { if ($isFg) { $s.FgMode = 1; $s.Fg = $n } else { $s.BgMode = 1; $s.Bg = $n } }
                    $i += 2
                }
                elseif ($sub -eq 2 -and $i + 4 -lt $list.Length) {
                    $r = $list[$i + 2]; $g = $list[$i + 3]; $b = $list[$i + 4]
                    if ($r -le 255 -and $g -le 255 -and $b -le 255) {
                        $v = ($r -shl 16) -bor ($g -shl 8) -bor $b
                        if ($isFg) { $s.FgMode = 2; $s.Fg = $v } else { $s.BgMode = 2; $s.Bg = $v }
                    }
                    $i += 4
                }
                elseif ($sub -eq 5 -or $sub -eq 2) { $i = $list.Length }   # malformed: ignore only this color
            }
        }
        return $s
    }
}

# --- Console model ---------------------------------------------------------------

class ConsoleCell {
    [int] $Scalar; [int] $Width; [ConsoleStyle] $Style
    ConsoleCell([int] $scalar, [int] $width, [ConsoleStyle] $style) { $this.Scalar = $scalar; $this.Width = $width; $this.Style = $style }
}

class ConsoleEntry {
    [string] $Stream
    [System.Collections.Generic.List[System.Collections.Generic.List[ConsoleCell]]] $Lines
    [int] $Version = 1
    [int] $CachedCols = -1
    [System.Collections.Generic.List[ConsoleCell[]]] $CachedRows = $null
    [System.Collections.Generic.List[int[]]] $CachedStarts = $null   # per wrapped row: logical line, first cell index
    ConsoleEntry([string] $stream) {
        $this.Stream = $stream
        $this.Lines = [System.Collections.Generic.List[System.Collections.Generic.List[ConsoleCell]]]::new()
        $this.Lines.Add([System.Collections.Generic.List[ConsoleCell]]::new())
    }
}

class ConsoleModel {
    hidden [int] $Cols
    hidden [int] $Rows
    hidden [System.Collections.Generic.List[ConsoleEntry]] $Entries = [System.Collections.Generic.List[ConsoleEntry]]::new()
    hidden [ConsoleEntry] $Current = $null
    hidden [int] $WriteCol = 0
    hidden [System.Collections.Specialized.OrderedDictionary] $Progress = [System.Collections.Specialized.OrderedDictionary]::new()
    hidden [string] $Prompt = 'PS>'
    hidden [System.Collections.Generic.List[int]] $Editor = [System.Collections.Generic.List[int]]::new()
    hidden [int] $Caret = 0
    hidden [string] $Composition = ''
    hidden [System.Collections.Generic.List[string]] $History = [System.Collections.Generic.List[string]]::new()
    hidden [int] $HistoryIndex = -1
    hidden [string] $Saved = ''
    hidden [int] $ScrollOffset = 0
    # Selection in logical positions (entry, line, cell), so it survives reflow.
    hidden [int[]] $SelA = $null
    hidden [int[]] $SelB = $null
    hidden [bool] $SelLines = $false
    # Per composed row: kind (0 transcript, 1 progress, 2 editor), entry, line, first cell; and the first visible row.
    hidden [System.Collections.Generic.List[int[]]] $RowMeta = [System.Collections.Generic.List[int[]]]::new()
    hidden [int] $ViewStart = 0
    static [ConsoleStyle] $Default = [ConsoleStyle]::new()

    ConsoleModel([int] $cols, [int] $rows) { $this.Cols = [Math]::Max(1, $cols); $this.Rows = [Math]::Max(1, $rows) }

    static [int[]] Scalars([string] $text) {
        $l = [System.Collections.Generic.List[int]]::new()
        foreach ($r in $text.EnumerateRunes()) { $l.Add($r.Value) }
        return $l.ToArray()
    }
    static [string] Text([System.Collections.Generic.IEnumerable[int]] $scalars) {
        $sb = [System.Text.StringBuilder]::new()
        foreach ($s in $scalars) { [void]$sb.Append([System.Text.Rune]::new($s).ToString()) }
        return $sb.ToString()
    }

    # Stream colors: ConsoleHost defaults, ConsoleHostUserInterface.cs:1409-1427
    # at PowerShell 1481b98f. A Console.BackgroundColor default is mode 0.
    static [ConsoleStyle] StreamStyle([string] $stream, [object] $fg, [object] $bg) {
        $s = [ConsoleStyle]::new()
        switch ($stream) {
            'Error' { $s.FgMode = 1; $s.Fg = [ConsoleCells]::ConsoleColorToPalette[12] }   # Red
            { $_ -in 'Warning', 'Verbose', 'Debug' } { $s.FgMode = 1; $s.Fg = [ConsoleCells]::ConsoleColorToPalette[14] }   # Yellow
        }
        if ($null -ne $fg) { $s.FgMode = 1; $s.Fg = [ConsoleCells]::ConsoleColorToPalette[[int]$fg -band 15] }
        if ($null -ne $bg) { $s.BgMode = 1; $s.Bg = [ConsoleCells]::ConsoleColorToPalette[[int]$bg -band 15] }
        return $s
    }

    hidden [void] SetCell([System.Collections.Generic.List[ConsoleCell]] $line, [int] $col, [ConsoleCell] $cell) {
        while ($line.Count -le $col) { $line.Add($null) }
        $line[$col] = $cell
    }

    [void] Write([string] $stream, [string] $text) { $this.Write($stream, $text, $null, $null) }
    [void] Write([string] $stream, [string] $text, [object] $fg, [object] $bg) {
        $style = [ConsoleModel]::StreamStyle($stream, $fg, $bg)
        if ($null -eq $this.Current -or $this.Current.Stream -ne $stream) {
            $this.Current = [ConsoleEntry]::new($stream); $this.Entries.Add($this.Current); $this.WriteCol = 0
        }
        $entry = $this.Current
        $entry.Version++; $entry.CachedRows = $null
        $parser = [ConsoleParser]::new()
        foreach ($a in $parser.Feed($text)) {
            $line = $entry.Lines[$entry.Lines.Count - 1]
            switch ($a.Kind) {
                'csi' { if ($a.Final -ceq 'm' -and $a.Private -eq '' -and $a.Intermediates -eq '') { $style = [ConsoleSgr]::Apply($style, $a.Params) } }
                'execute' {
                    switch ($a.Code) {
                        10 { $entry.Lines.Add([System.Collections.Generic.List[ConsoleCell]]::new()); $this.WriteCol = 0 }   # LF; CR before it already set column 0
                        13 { $this.WriteCol = 0 }                                     # CR
                        8 { $this.WriteCol = [Math]::Max(0, $this.WriteCol - 1) }     # BS
                        9 {                                                            # TAB: spaces to the next multiple of 8
                            $target = ([Math]::Floor($this.WriteCol / 8) + 1) * 8
                            while ($this.WriteCol -lt $target) { $this.SetCell($line, $this.WriteCol, [ConsoleCell]::new(32, 1, $style.Clone())); $this.WriteCol++ }
                        }
                    }
                }
                'print' {
                    $w = [ConsoleWidth]::Of($a.Code)
                    if ($w -eq 1) { $this.SetCell($line, $this.WriteCol, [ConsoleCell]::new($a.Code, 1, $style.Clone())); $this.WriteCol++ }
                    elseif ($w -eq 2) {
                        $this.SetCell($line, $this.WriteCol, [ConsoleCell]::new($a.Code, 2, $style.Clone()))
                        $this.SetCell($line, $this.WriteCol + 1, [ConsoleCell]::new(0, 0, $style.Clone()))
                        $this.WriteCol += 2
                    }
                }
            }
        }
    }

    [void] WriteProgress([int] $activityId, [string] $activity, [string] $status, [int] $percent, [bool] $completed) {
        if ($completed) { $this.Progress.Remove($activityId) }
        else { $this.Progress[[object]$activityId] = "${activity}: ${status} [${percent}%]" }
    }

    [void] SetPrompt([string] $prompt) { $this.Prompt = $prompt }

    [void] EditorInsert([string] $text) {
        $this.ScrollOffset = 0
        $s = [ConsoleModel]::Scalars($text)
        $this.Editor.InsertRange($this.Caret, $s); $this.Caret += $s.Length; $this.Composition = ''
    }
    [void] EditorBackspace() { $this.ScrollOffset = 0; if ($this.Caret -gt 0) { $this.Editor.RemoveAt($this.Caret - 1); $this.Caret-- } }
    [void] EditorDelete() { $this.ScrollOffset = 0; if ($this.Caret -lt $this.Editor.Count) { $this.Editor.RemoveAt($this.Caret) } }
    [void] EditorMove([int] $delta) { $this.ScrollOffset = 0; $this.Caret = [Math]::Max(0, [Math]::Min($this.Editor.Count, $this.Caret + $delta)) }
    [void] EditorHome() { $this.ScrollOffset = 0; $this.Caret = 0 }
    [void] EditorEnd() { $this.ScrollOffset = 0; $this.Caret = $this.Editor.Count }
    [void] EditorSetComposition([string] $text) { $this.ScrollOffset = 0; $this.Composition = $text }

    hidden [void] SetEditor([string] $text) {
        $this.Editor.Clear(); $this.Editor.AddRange([ConsoleModel]::Scalars($text)); $this.Caret = $this.Editor.Count
    }
    [void] HistoryUp() {
        $this.ScrollOffset = 0
        if ($this.History.Count -eq 0) { return }
        if ($this.HistoryIndex -eq -1) { $this.Saved = [ConsoleModel]::Text($this.Editor); $this.HistoryIndex = $this.History.Count - 1 }
        elseif ($this.HistoryIndex -gt 0) { $this.HistoryIndex-- }
        $this.SetEditor($this.History[$this.HistoryIndex])
    }
    [void] HistoryDown() {
        $this.ScrollOffset = 0
        if ($this.HistoryIndex -eq -1) { return }
        if ($this.HistoryIndex -lt $this.History.Count - 1) { $this.HistoryIndex++; $this.SetEditor($this.History[$this.HistoryIndex]) }
        else { $this.HistoryIndex = -1; $this.SetEditor($this.Saved) }
    }
    [string] Submit() {
        $cmd = [ConsoleModel]::Text($this.Editor)
        $this.History.Add($cmd); $this.HistoryIndex = -1; $this.Saved = ''
        $this.Editor.Clear(); $this.Caret = 0; $this.Composition = ''; $this.Current = $null; $this.ScrollOffset = 0
        return $cmd
    }
    [void] Scroll([int] $deltaRows) { $this.ScrollOffset = [Math]::Max(0, $this.ScrollOffset - $deltaRows) }
    [void] Resize([int] $cols, [int] $rows) {
        $this.Cols = [Math]::Max(1, $cols); $this.Rows = [Math]::Max(1, $rows)
        foreach ($e in $this.Entries) { $e.CachedRows = $null }
    }

    # Wraps one logical line at cols; a wide character that would start in the
    # last column moves to the next row, leaving that column empty.
    hidden [System.Collections.Generic.List[ConsoleCell[]]] Wrap([System.Collections.Generic.List[ConsoleCell]] $line, [int] $cols) {
        return $this.Wrap($line, $cols, [System.Collections.Generic.List[int]]::new())
    }
    # $starts receives each wrapped row's first logical cell index.
    hidden [System.Collections.Generic.List[ConsoleCell[]]] Wrap([System.Collections.Generic.List[ConsoleCell]] $line, [int] $cols, [System.Collections.Generic.List[int]] $starts) {
        $wrapped = [System.Collections.Generic.List[ConsoleCell[]]]::new()
        $row = [System.Collections.Generic.List[ConsoleCell]]::new()
        $empty = [ConsoleCell]::new(0, 1, [ConsoleModel]::Default)
        $i = 0; $rowStart = 0
        while ($i -lt $line.Count) {
            $cell = if ($null -ne $line[$i]) { $line[$i] } else { $empty }
            if ($cell.Width -eq 2) {
                if ($row.Count -eq $cols - 1) { $row.Add($empty); $wrapped.Add($row.ToArray()); $starts.Add($rowStart); $row.Clear(); $rowStart = $i }
                $row.Add($cell)
                $next = if ($i + 1 -lt $line.Count -and $null -ne $line[$i + 1]) { $line[$i + 1] } else { [ConsoleCell]::new(0, 0, $cell.Style) }
                $row.Add($next); $i += 2
            }
            else { $row.Add($cell); $i++ }
            if ($row.Count -ge $cols) { $wrapped.Add($row.GetRange(0, $cols).ToArray()); $starts.Add($rowStart); $row.Clear(); $rowStart = $i }
        }
        if ($row.Count -gt 0 -or $wrapped.Count -eq 0) {
            while ($row.Count -lt $cols) { $row.Add($empty) }
            $wrapped.Add($row.ToArray()); $starts.Add($rowStart)
        }
        return $wrapped
    }
    hidden [System.Collections.Generic.List[ConsoleCell[]]] EntryRows([ConsoleEntry] $e, [int] $cols) {
        if ($e.CachedCols -eq $cols -and $null -ne $e.CachedRows) { return $e.CachedRows }
        $all = [System.Collections.Generic.List[ConsoleCell[]]]::new()
        $meta = [System.Collections.Generic.List[int[]]]::new()
        for ($li = 0; $li -lt $e.Lines.Count; $li++) {
            $starts = [System.Collections.Generic.List[int]]::new()
            $all.AddRange($this.Wrap($e.Lines[$li], $cols, $starts))
            foreach ($st in $starts) { $meta.Add(@($li, $st)) }
        }
        $e.CachedCols = $cols; $e.CachedRows = $all; $e.CachedStarts = $meta
        return $all
    }

    hidden [void] AddCells([System.Collections.Generic.List[ConsoleCell]] $line, [int[]] $scalars, [ConsoleStyle] $style) {
        foreach ($s in $scalars) {
            $w = [ConsoleWidth]::Of($s)
            $line.Add([ConsoleCell]::new($s, $w, $style))
            if ($w -eq 2) { $line.Add([ConsoleCell]::new(0, 0, $style)) }
        }
    }

    # Composes the visible frame into $target (cols * rows * 3 words) and
    # returns the cursor as @{ Col; Row; Visible }.
    [hashtable] Compose([int[]] $target) {
        $nc = $this.Cols; $nr = $this.Rows
        $all = [System.Collections.Generic.List[ConsoleCell[]]]::new()
        $meta = [System.Collections.Generic.List[int[]]]::new()
        for ($ei = 0; $ei -lt $this.Entries.Count; $ei++) {
            $all.AddRange($this.EntryRows($this.Entries[$ei], $nc))
            foreach ($m in $this.Entries[$ei].CachedStarts) { $meta.Add(@(0, $ei, $m[0], $m[1])) }
        }

        # Progress rows: ConsoleHost ProgressForegroundColor Black, ProgressBackgroundColor Yellow.
        $ps = [ConsoleStyle]::new(0, 1, 11, 1, 0)
        foreach ($text in $this.Progress.Values) {
            $pl = [System.Collections.Generic.List[ConsoleCell]]::new()
            foreach ($r in ([string]$text).EnumerateRunes()) { $pl.Add([ConsoleCell]::new($r.Value, [ConsoleWidth]::Of($r.Value), $ps)) }
            while ($pl.Count -lt $nc) { $pl.Add([ConsoleCell]::new(0, 1, $ps)) }
            $all.Add($pl.GetRange(0, $nc).ToArray()); $meta.Add(@(1, -1, -1, 0))
        }

        # Editor: prompt, a space, text before the caret, composition (inverse), the rest.
        $el = [System.Collections.Generic.List[ConsoleCell]]::new()
        $d = [ConsoleModel]::Default
        $this.AddCells($el, [ConsoleModel]::Scalars($this.Prompt + ' '), $d)
        $this.AddCells($el, $this.Editor.GetRange(0, $this.Caret).ToArray(), $d)
        $caretCell = $el.Count
        if ($this.Composition.Length -gt 0) { $this.AddCells($el, [ConsoleModel]::Scalars($this.Composition), [ConsoleStyle]::new(0, 0, 0, 0, 8)) }
        $this.AddCells($el, $this.Editor.GetRange($this.Caret, $this.Editor.Count - $this.Caret).ToArray(), $d)
        $editorStart = $all.Count
        $editorRows = $this.Wrap($el, $nc); $all.AddRange($editorRows)
        foreach ($er2 in $editorRows) { $meta.Add(@(2, -1, -1, 0)) }

        $caretRow = $editorStart + [Math]::Floor($caretCell / $nc)
        $total = $all.Count
        $scroll = [Math]::Min($this.ScrollOffset, [Math]::Max(0, $total - $nr))
        $start = if ($total -le $nr) { 0 } else { $total - $nr - $scroll }
        $screenRow = $caretRow - $start

        $this.RowMeta = $meta; $this.ViewStart = $start
        [Array]::Clear($target, 0, $target.Length)
        for ($y = 0; $y -lt $nr; $y++) {
            $li = $start + $y
            $rowCells = if ($li -ge 0 -and $li -lt $total) { $all[$li] } else { $null }
            for ($x = 0; $x -lt $nc; $x++) {
                if ($null -ne $rowCells -and $x -lt $rowCells.Length) {
                    $c = $rowCells[$x]; $st = $c.Style
                    if ($null -ne $this.SelA -and $meta[$li][0] -eq 0 -and $this.IsSelected($meta[$li][1], $meta[$li][2], $meta[$li][3] + $x)) { $st = $st.Clone(); $st.Attrs = $st.Attrs -bxor 8 }
                    [ConsoleCells]::Put($target, $y * $nc + $x, $c.Scalar, $c.Width, $st)
                }
                else { [ConsoleCells]::Put($target, $y * $nc + $x, 0, 1, $d) }
            }
        }
        return @{ Col = $caretCell % $nc; Row = [Math]::Max(0, [Math]::Min($nr - 1, $screenRow)); Visible = ($screenRow -ge 0 -and $screenRow -lt $nr) }
    }

    # --- Selection -------------------------------------------------------------
    static [int] ComparePosition([int[]] $a, [int[]] $b) {
        for ($k = 0; $k -lt 3; $k++) { if ($a[$k] -ne $b[$k]) { return [Math]::Sign($a[$k] - $b[$k]) } }
        return 0
    }
    hidden [object[]] Ordered() {
        if ([ConsoleModel]::ComparePosition($this.SelA, $this.SelB) -le 0) { return @(, $this.SelA) + @(, $this.SelB) }
        return @(, $this.SelB) + @(, $this.SelA)
    }
    [bool] IsSelected([int] $entry, [int] $line, [int] $cell) {
        if ($null -eq $this.SelA) { return $false }
        $o = $this.Ordered(); [int[]] $lo = $o[0]; [int[]] $hi = $o[1]
        if ($this.SelLines) { [int[]] $p = @($entry, $line, 0); [int[]] $a = @($lo[0], $lo[1], 0); [int[]] $b = @($hi[0], $hi[1], 0) }
        else { [int[]] $p = @($entry, $line, $cell); $a = $lo; $b = $hi }
        return [ConsoleModel]::ComparePosition($p, $a) -ge 0 -and [ConsoleModel]::ComparePosition($p, $b) -le 0
    }
    # The logical position (entry, line, cell) under a visible cell, or $null outside the transcript.
    [int[]] PositionAt([int] $row, [int] $col) {
        $li = $this.ViewStart + $row
        if ($row -lt 0 -or $li -ge $this.RowMeta.Count) { return $null }
        $m = $this.RowMeta[$li]
        if ($m[0] -ne 0) { return $null }
        $cell = $m[3] + [Math]::Max(0, [Math]::Min($col, $this.Cols - 1))
        return [int[]]@($m[1], $m[2], $cell)
    }
    # The kind of a visible row: 0 transcript, 1 progress, 2 editor, -1 none.
    [int] RowKind([int] $row) { $li = $this.ViewStart + $row; if ($row -lt 0 -or $li -ge $this.RowMeta.Count) { return -1 }; return $this.RowMeta[$li][0] }
    [void] SetSelection([int[]] $anchor, [int[]] $focus, [bool] $byLine) { $this.SelA = $anchor; $this.SelB = $focus; $this.SelLines = $byLine }
    [void] ClearSelection() { $this.SelA = $null; $this.SelB = $null; $this.SelLines = $false }
    [bool] HasSelection() { return $null -ne $this.SelA }
    # The selected text: logical lines joined with LF, trailing blanks trimmed per line.
    [string] SelectionText() {
        if ($null -eq $this.SelA) { return '' }
        $o = $this.Ordered(); [int[]] $lo = $o[0]; [int[]] $hi = $o[1]
        $out = [System.Collections.Generic.List[string]]::new()
        for ($e = $lo[0]; $e -le $hi[0]; $e++) {
            $lines = $this.Entries[$e].Lines
            $l0 = if ($e -eq $lo[0]) { $lo[1] } else { 0 }
            $l1 = if ($e -eq $hi[0]) { $hi[1] } else { $lines.Count - 1 }
            for ($l = $l0; $l -le $l1; $l++) {
                $cells = $lines[$l]
                $c0 = if (-not $this.SelLines -and $e -eq $lo[0] -and $l -eq $lo[1]) { $lo[2] } else { 0 }
                $c1 = if (-not $this.SelLines -and $e -eq $hi[0] -and $l -eq $hi[1]) { $hi[2] } else { $cells.Count - 1 }
                $sb = [System.Text.StringBuilder]::new()
                for ($c = $c0; $c -le [Math]::Min($c1, $cells.Count - 1); $c++) {
                    $cell = $cells[$c]
                    if ($null -eq $cell) { [void]$sb.Append(' ') }
                    elseif ($cell.Width -eq 0) { }
                    elseif ($cell.Scalar -eq 0) { [void]$sb.Append(' ') }
                    else { [void]$sb.Append([System.Text.Rune]::new($cell.Scalar).ToString()) }
                }
                $out.Add($sb.ToString().TrimEnd())
            }
        }
        return [string]::Join("`n", $out)
    }

    [int] GetCols() { return $this.Cols }
    [int] GetRows() { return $this.Rows }
}

# --- Diff ----------------------------------------------------------------------

class ConsoleDiff {
    # Returns draw ops: @{ Kind='fill'; Row; Col; Count; Bg } and
    # @{ Kind='text'; Row; Col; Text; Cells; Fg; Attrs }, colors as 0xRRGGBB.
    static [System.Collections.Generic.List[hashtable]] Frames([int[]] $previous, [int[]] $next, [int] $cols, [int] $rows) {
        $ops = [System.Collections.Generic.List[hashtable]]::new()
        for ($r = 0; $r -lt $rows; $r++) {
            $ro = $r * $cols * 3
            $min = -1; $max = -1
            for ($c = 0; $c -lt $cols; $c++) {
                $i = $ro + $c * 3
                if ($null -eq $previous -or $previous[$i] -ne $next[$i] -or $previous[$i + 1] -ne $next[$i + 1] -or $previous[$i + 2] -ne $next[$i + 2]) {
                    if ($min -eq -1) { $min = $c }; $max = $c
                }
            }
            if ($min -eq -1) { continue }
            # Never start on a continuation cell or end on a wide character's first cell, in either frame.
            foreach ($f in @($next, $previous)) {
                if ($null -eq $f) { continue }
                while ($min -gt 0 -and ((($f[$ro + $min * 3]) -shr 21) -band 3) -eq 0) { $min-- }
                while ($max -lt $cols - 1 -and ((($f[$ro + $max * 3]) -shr 21) -band 3) -eq 2) { $max++ }
            }
            $col = $min
            while ($col -le $max) {
                $key = [ConsoleDiff]::Style($next, $ro + $col * 3)
                $end = $col + 1
                while ($end -le $max -and ([ConsoleDiff]::Style($next, $ro + $end * 3) -eq $key)) { $end++ }
                $parts = $key -split ','
                $ops.Add(@{ Kind = 'fill'; Row = $r; Col = $col; Count = $end - $col; Bg = [int]$parts[1] })
                $sb = [System.Text.StringBuilder]::new()
                for ($c = $col; $c -lt $end; $c++) {
                    $w0 = $next[$ro + $c * 3]
                    $width = ($w0 -shr 21) -band 3; $scalar = $w0 -band 0x1fffff
                    if ($width -eq 0) { continue }
                    if ($scalar -eq 0) { [void]$sb.Append(' ') } else { [void]$sb.Append([System.Text.Rune]::new($scalar).ToString()) }
                }
                $ops.Add(@{ Kind = 'text'; Row = $r; Col = $col; Text = $sb.ToString(); Cells = $end - $col; Fg = [int]$parts[0]; Attrs = [int]$parts[2] })
                $col = $end
            }
        }
        return $ops
    }

    # Resolved "fg,bg,attrs" of the cell at word offset $i; inverse swaps fg and bg.
    static [string] Style([int[]] $f, [int] $i) {
        $attrs = ($f[$i] -shr 23) -band 0x3f
        $fg = [ConsoleCells]::Resolve($f[$i + 1] -band 0xffffff, ($f[$i + 1] -shr 24) -band 3, $true)
        $bg = [ConsoleCells]::Resolve($f[$i + 2] -band 0xffffff, ($f[$i + 2] -shr 24) -band 3, $false)
        if ($attrs -band 8) { $t = $fg; $fg = $bg; $bg = $t }
        return "$fg,$bg,$attrs"
    }
}

# --- Frame ring ------------------------------------------------------------------

class ConsoleFrameRing {
    # Layout (docs/console-reference.md): a 64-byte control block ('PWRC',
    # version, newest slot, reader slot), then three slots of a 64-byte header
    # ('PWFR', version, header size, sequence, cols, rows, cursor, flags, cell
    # format) and cols * rows * 12 bytes of cells.
    hidden [IntPtr] $Base; hidden [int] $Cols; hidden [int] $Rows; hidden [int] $Stride
    static [int] $ControlMagic = 0x43525750
    static [int] $SlotMagic = 0x52465750

    static [int] ByteLength([int] $cols, [int] $rows) { return 64 + 3 * (64 + $cols * $rows * 12) }

    ConsoleFrameRing([IntPtr] $base, [int] $cols, [int] $rows) {
        $this.Base = $base; $this.Cols = $cols; $this.Rows = $rows; $this.Stride = 64 + $cols * $rows * 12
        $m = [System.Runtime.InteropServices.Marshal]
        if ($m::ReadInt32($base, 0) -ne [ConsoleFrameRing]::ControlMagic) {
            $m::WriteInt32($base, 0, [ConsoleFrameRing]::ControlMagic); $m::WriteInt32($base, 4, 1)
            $m::WriteInt32($base, 8, -1); $m::WriteInt32($base, 12, -1)
        }
    }
    hidden [int] SlotOffset([int] $slot) { return 64 + $slot * $this.Stride }

    # Chooses the lowest slot that is neither newest nor being read.
    [int] BeginWrite() {
        $m = [System.Runtime.InteropServices.Marshal]
        $newest = $m::ReadInt32($this.Base, 8); $reader = $m::ReadInt32($this.Base, 12)
        for ($i = 0; $i -lt 3; $i++) { if ($i -ne $newest -and $i -ne $reader) { return $i } }
        for ($i = 0; $i -lt 3; $i++) { if ($i -ne $newest) { return $i } }
        return 0
    }

    [long] Commit([int] $slot, [int[]] $cells, [int] $cursorCol, [int] $cursorRow, [bool] $cursorVisible) {
        $m = [System.Runtime.InteropServices.Marshal]
        $o = $this.SlotOffset($slot)
        $m::Copy($cells, 0, [IntPtr]::Add($this.Base, $o + 64), $this.Cols * $this.Rows * 3)
        $m::WriteInt32($this.Base, $o, [ConsoleFrameRing]::SlotMagic)
        $m::WriteInt16($this.Base, $o + 4, 1); $m::WriteInt16($this.Base, $o + 6, 64)
        $m::WriteInt32($this.Base, $o + 16, $this.Cols); $m::WriteInt32($this.Base, $o + 20, $this.Rows)
        $m::WriteInt32($this.Base, $o + 24, $cursorCol); $m::WriteInt32($this.Base, $o + 28, $cursorRow)
        $m::WriteInt32($this.Base, $o + 32, [int]$cursorVisible); $m::WriteInt32($this.Base, $o + 36, 1)
        for ($z = 40; $z -lt 64; $z += 4) { $m::WriteInt32($this.Base, $o + $z, 0) }
        $max = [long]0
        for ($i = 0; $i -lt 3; $i++) { $s = $m::ReadInt64($this.Base, $this.SlotOffset($i) + 8); if ($s -gt $max) { $max = $s } }
        $seq = $max + 1
        $m::WriteInt64($this.Base, $o + 8, $seq)          # the sequence is written last
        $m::WriteInt32($this.Base, 8, $slot)              # then the newest slot
        return $seq
    }

    # Returns a copy of the newest frame, or $null before the first commit.
    [hashtable] AcquireLatest() {
        $m = [System.Runtime.InteropServices.Marshal]
        while ($true) {
            $n = $m::ReadInt32($this.Base, 8)
            if ($n -lt 0 -or $n -ge 3) { return $null }
            $m::WriteInt32($this.Base, 12, $n)
            $o = $this.SlotOffset($n)
            $s1 = $m::ReadInt64($this.Base, $o + 8)
            if ($s1 -eq 0) { $m::WriteInt32($this.Base, 12, -1); return $null }
            if ($m::ReadInt32($this.Base, 8) -ne $n) { $m::WriteInt32($this.Base, 12, -1); continue }
            $fc = $m::ReadInt32($this.Base, $o + 16); $fr = $m::ReadInt32($this.Base, $o + 20)
            $cells = [int[]]::new($fc * $fr * 3)
            $m::Copy([IntPtr]::Add($this.Base, $o + 64), $cells, 0, $cells.Length)
            $frame = @{ Sequence = $s1; Cols = $fc; Rows = $fr; Cells = $cells
                        CursorCol = $m::ReadInt32($this.Base, $o + 24); CursorRow = $m::ReadInt32($this.Base, $o + 28)
                        CursorVisible = ($m::ReadInt32($this.Base, $o + 32) -band 1) -eq 1 }
            if ($m::ReadInt64($this.Base, $o + 8) -ne $s1) { $m::WriteInt32($this.Base, 12, -1); continue }
            $m::WriteInt32($this.Base, 12, -1)
            return $frame
        }
        return $null
    }
}

# --- Exported functions ------------------------------------------------------------

function New-ConsoleModel { param([Parameter(Mandatory)][int] $Columns, [Parameter(Mandatory)][int] $Rows) [ConsoleModel]::new($Columns, $Rows) }
function New-ConsoleFrame { param([Parameter(Mandatory)][object] $Model) , [int[]]::new($Model.GetCols() * $Model.GetRows() * 3) }
function Compare-ConsoleFrame {
    param([AllowNull()][int[]] $Previous, [Parameter(Mandatory)][int[]] $Next, [Parameter(Mandatory)][int] $Columns, [Parameter(Mandatory)][int] $Rows)
    , [ConsoleDiff]::Frames($Previous, $Next, $Columns, $Rows)
}
function New-ConsoleFrameRing { param([Parameter(Mandatory)][IntPtr] $Base, [Parameter(Mandatory)][int] $Columns, [Parameter(Mandatory)][int] $Rows) [ConsoleFrameRing]::new($Base, $Columns, $Rows) }
function Get-ConsoleFrameRingSize { param([Parameter(Mandatory)][int] $Columns, [Parameter(Mandatory)][int] $Rows) [ConsoleFrameRing]::ByteLength($Columns, $Rows) }
function Get-ConsoleCellWidth { param([Parameter(Mandatory)][int] $Scalar) [ConsoleWidth]::Of($Scalar) }
function Resolve-ConsoleColor { param([int] $Value, [int] $Mode, [switch] $Foreground) [ConsoleCells]::Resolve($Value, $Mode, $Foreground.IsPresent) }

Export-ModuleMember -Function New-ConsoleModel, New-ConsoleFrame, Compare-ConsoleFrame, New-ConsoleFrameRing,
    Get-ConsoleFrameRingSize, Get-ConsoleCellWidth, Resolve-ConsoleColor
