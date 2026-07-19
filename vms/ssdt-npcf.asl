DefinitionBlock ("ssdt-npcf.aml", "SSDT", 0x01, "CUST", "NPCF", 0x00000001)
{
    Scope (\_SB)
    {
        Device (NPCF)
        {
            Name (CNPF, Zero)
            Name (AMAT, 0xA0)
            Name (ACBT, 0xA0)
            Name (DCBT, Zero)
            Name (DBAC, Zero)
            Name (DBDC, One)
            Name (AMIT, 0xFFB0)
            Name (ATPP, 0x0118)
            Name (DTPP, Zero)
            Name (TPPL, 0x0001C138)
            Name (DROS, Zero)

            Method (_HID, 0, NotSerialized) { Return ("NVDA0820") }
            Name (_UID, "NPCF")
            Method (_STA, 0, NotSerialized) { Return (0x0F) }

            Method (_DSM, 4, Serialized)
            {
                If ((Arg0 == ToUUID ("36b49710-2483-11e7-9598-0800200c9a66")))
                    { Return (NPCF (Arg0, Arg1, Arg2, Arg3)) }
                Return (Buffer (One) { 0x00 })
            }

            Method (NPCF, 4, Serialized)
            {
                If ((ToInteger (Arg1) != 0x0200)) { Return (0x80000001) }
                Switch (ToInteger (Arg2))
                {
                    Case (Zero)
                    {
                        Return (Buffer (0x04) { 0xBF, 0x06, 0x00, 0x00 })
                    }
                    Case (One)
                    {
                        Return (Buffer (0x0E) {
                            0x20, 0x03, 0x01, 0x00, 0x25, 0x04, 0x05, 0x01,
                            0x01, 0x03, 0x00, 0x00, 0x00, 0xA9
                        })
                    }
                    Case (0x02)
                    {
                        Name (PBD2, Buffer (0x31) { 0x00 })
                        CreateByteField (PBD2, Zero, PTV2)
                        CreateByteField (PBD2, One, PHB2)
                        CreateByteField (PBD2, 0x02, GSB2)
                        CreateByteField (PBD2, 0x03, CTB2)
                        CreateByteField (PBD2, 0x04, NCE2)
                        PTV2 = 0x25; PHB2 = 0x05; GSB2 = 0x10; CTB2 = 0x1C; NCE2 = One
                        CreateWordField (PBD2, 0x05, TGPA)
                        CreateWordField (PBD2, 0x07, TGPD)
                        CreateByteField (PBD2, 0x15, PC01)
                        CreateByteField (PBD2, 0x16, PC02)
                        CreateWordField (PBD2, 0x19, TPPA)
                        CreateWordField (PBD2, 0x1B, TPPD)
                        CreateWordField (PBD2, 0x1D, MAGA)
                        CreateWordField (PBD2, 0x1F, MAGD)
                        CreateWordField (PBD2, 0x21, MIGA)
                        CreateWordField (PBD2, 0x23, MIGD)
                        CreateDWordField (PBD2, 0x25, DROP)
                        CreateDWordField (PBD2, 0x29, LTBC)
                        CreateDWordField (PBD2, 0x2D, STBC)
                        TGPA = ACBT; TGPD = DCBT; PC01 = Zero
                        PC02 = (DBAC | (DBDC << One))
                        TPPA = ATPP; TPPD = DTPP; MAGA = AMAT; MIGA = AMIT
                        MAGD = Zero; MIGD = Zero; DROP = DROS
                        Return (PBD2)
                    }
                    Case (0x03)
                    {
                        Return (Buffer (0x1E) {
                            0x11, 0x04, 0x0D, 0x02, 0x00, 0xFF, 0x00, 0x3C,
                            0x3F, 0x3F, 0x46, 0x46, 0x57, 0x57, 0x5A, 0x5A,
                            0x5E, 0x05, 0xFF, 0x00, 0x2D, 0x33, 0x33, 0x37,
                            0x37, 0x3F, 0x3F, 0x43, 0x43, 0x46
                        })
                    }
                    Case (0x05)
                    {
                        Return (Buffer (0x28) {
                            0x11, 0x04, 0x24, 0x01,
                            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00
                        })
                    }
                }
                Return (0x80000002)
            }
        }
    }
}
