/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of UsbCTabl.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x00000F46 (3910)
 *     Revision         0x02
 *     Checksum         0x2D
 *     OEM ID           "_ASUS_"
 *     OEM Table ID     "UsbCTabl"
 *     OEM Revision     0x00001000 (4096)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20210930 (539035952)
 */
DefinitionBlock ("", "SSDT", 2, "_ASUS_", "UsbCTabl", 0x00001000)
{
    External (_SB_.PC00.LPCB.EC0_, UnknownObj)
    External (_SB_.PC00.LPCB.EC0_.ECOK, IntObj)
    External (_SB_.PC00.LPCB.EC0_.MUT0, MutexObj)
    External (_SB_.PC00.XHCI.RHUB, DeviceObj)
    External (P8XH, MethodObj)    // 2 Arguments
    External (TBTS, UnknownObj)
    External (TP1C, IntObj)
    External (TP1D, UnknownObj)
    External (TP1P, UnknownObj)
    External (TP1T, UnknownObj)
    External (TP1U, UnknownObj)
    External (TP2C, IntObj)
    External (TP2D, UnknownObj)
    External (TP2P, UnknownObj)
    External (TP2T, UnknownObj)
    External (TP2U, UnknownObj)
    External (TP3C, IntObj)
    External (TP3D, UnknownObj)
    External (TP3P, UnknownObj)
    External (TP3T, UnknownObj)
    External (TP3U, UnknownObj)
    External (TP4C, IntObj)
    External (TP4D, UnknownObj)
    External (TP4P, UnknownObj)
    External (TP4T, UnknownObj)
    External (TP4U, UnknownObj)
    External (TP5C, IntObj)
    External (TP5D, UnknownObj)
    External (TP5P, UnknownObj)
    External (TP5T, UnknownObj)
    External (TP5U, UnknownObj)
    External (TP6C, IntObj)
    External (TP6D, UnknownObj)
    External (TP6P, UnknownObj)
    External (TP6T, UnknownObj)
    External (TP6U, UnknownObj)
    External (TP7C, IntObj)
    External (TP7D, UnknownObj)
    External (TP7P, UnknownObj)
    External (TP7T, UnknownObj)
    External (TP7U, UnknownObj)
    External (TP8C, IntObj)
    External (TP8D, UnknownObj)
    External (TP8P, UnknownObj)
    External (TP8T, UnknownObj)
    External (TP8U, UnknownObj)
    External (TP9C, IntObj)
    External (TP9D, UnknownObj)
    External (TP9P, UnknownObj)
    External (TP9T, UnknownObj)
    External (TP9U, UnknownObj)
    External (TPAC, IntObj)
    External (TPAD, UnknownObj)
    External (TPAP, UnknownObj)
    External (TPAT, UnknownObj)
    External (TPAU, UnknownObj)
    External (TTUP, UnknownObj)
    External (UBCB, UnknownObj)
    External (UCMS, UnknownObj)
    External (UDRS, UnknownObj)
    External (USTC, UnknownObj)
    External (XDCE, UnknownObj)

    Scope (\_SB)
    {
        Device (UBTC)
        {
            Name (_HID, EisaId ("USBC000"))  // _HID: Hardware ID
            Name (_CID, EisaId ("PNP0CA0"))  // _CID: Compatible ID
            Name (_UID, Zero)  // _UID: Unique ID
            Name (_DDN, "USB Type C")  // _DDN: DOS Device Name
            Method (MGBS, 0, Serialized)
            {
                If ((UCMS == 0x02))
                {
                    Local0 = 0x0100
                }
                Else
                {
                    Local0 = 0x10
                }

                Return (Local0)
            }

            Method (UCMI, 0, Serialized)
            {
                Local0 = 0x10
                Local1 = (UBCB + Local0)
                Return (Local1)
            }

            Method (UCMO, 0, Serialized)
            {
                Local0 = MGBS ()
                Local0 = (Local0 + 0x10)
                Local1 = (UBCB + Local0)
                Return (Local1)
            }

            Name (CRS, Buffer (0x0E)
            {
                /* 0000 */  0x86, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,  // ........
                /* 0008 */  0x00, 0x10, 0x00, 0x00, 0x79, 0x00               // ....y.
            })
            OperationRegion (USBC, SystemMemory, UBCB, 0x10)
            Field (USBC, ByteAcc, Lock, Preserve)
            {
                VER1,   8, 
                VER2,   8, 
                RSV1,   8, 
                RSV2,   8, 
                CCI0,   8, 
                CCI1,   8, 
                CCI2,   8, 
                CCI3,   8, 
                CTL0,   8, 
                CTL1,   8, 
                CTL2,   8, 
                CTL3,   8, 
                CTL4,   8, 
                CTL5,   8, 
                CTL6,   8, 
                CTL7,   8
            }

            OperationRegion (USCI, SystemMemory, UCMI (), MGBS ())
            Field (USCI, ByteAcc, Lock, Preserve)
            {
                MGI0,   8, 
                MGI1,   8, 
                MGI2,   8, 
                MGI3,   8, 
                MGI4,   8, 
                MGI5,   8, 
                MGI6,   8, 
                MGI7,   8, 
                MGI8,   8, 
                MGI9,   8, 
                MGIA,   8, 
                MGIB,   8, 
                MGIC,   8, 
                MGID,   8, 
                MGIE,   8, 
                MGIF,   8
            }

            OperationRegion (UCSO, SystemMemory, UCMO (), MGBS ())
            Field (UCSO, ByteAcc, Lock, Preserve)
            {
                MGO0,   8, 
                MGO1,   8, 
                MGO2,   8, 
                MGO3,   8, 
                MGO4,   8, 
                MGO5,   8, 
                MGO6,   8, 
                MGO7,   8, 
                MGO8,   8, 
                MGO9,   8, 
                MGOA,   8, 
                MGOB,   8, 
                MGOC,   8, 
                MGOD,   8, 
                MGOE,   8, 
                MGOF,   8
            }

            Method (_CRS, 0, Serialized)  // _CRS: Current Resource Settings
            {
                CreateDWordField (CRS, 0x04, CBAS)
                CBAS = UBCB /* External reference */
                Return (CRS) /* \_SB_.UBTC.CRS_ */
            }

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If ((USTC == One))
                {
                    If (((UCMS == One) || (UCMS == 0x02)))
                    {
                        Return (0x0F)
                    }
                }

                Return (Zero)
            }

            Method (RUCC, 3, Serialized)
            {
                If (((Arg0 <= 0x0A) && (Arg0 >= One)))
                {
                    If ((Arg1 == One))
                    {
                        Return (\_SB.UBTC.TUPC (One, FTPT (Arg0), Arg2))
                    }
                    Else
                    {
                        Return (\_SB.UBTC.TPLD (One, FPMN (Arg0)))
                    }
                }
                ElseIf ((Arg1 == One))
                {
                    Return (\_SB.UBTC.TUPC (Zero, Zero, Zero))
                }
                Else
                {
                    Return (\_SB.UBTC.TPLD (Zero, Zero))
                }
            }

            Method (FTPT, 1, Serialized)
            {
                Switch (ToInteger (Arg0))
                {
                    Case (One)
                    {
                        Local0 = (TP1D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x02)
                    {
                        Local0 = (TP2D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x03)
                    {
                        Local0 = (TP3D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x04)
                    {
                        Local0 = (TP4D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x05)
                    {
                        Local0 = (TP5D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x06)
                    {
                        Local0 = (TP6D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x07)
                    {
                        Local0 = (TP7D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x08)
                    {
                        Local0 = (TP8D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x09)
                    {
                        Local0 = (TP9D >> One)
                        Local0 &= 0x03
                    }
                    Case (0x0A)
                    {
                        Local0 = (TPAD >> One)
                        Local0 &= 0x03
                    }
                    Default
                    {
                        Local0 = 0xFF
                    }

                }

                Switch (ToInteger (Local0))
                {
                    Case (Zero)
                    {
                        Return (0x09)
                    }
                    Case (One)
                    {
                        Return (0x09)
                    }
                    Case (0x02)
                    {
                        Return (0x09)
                    }
                    Case (0x03)
                    {
                        Return (Zero)
                    }

                }

                Return (0x09)
            }

            Method (FPMN, 1, Serialized)
            {
                Switch (ToInteger (Arg0))
                {
                    Case (One)
                    {
                        Local0 = (TP1D >> One)
                        Local0 &= 0x03
                        Local1 = (TP1D & One)
                        Local2 = TP1P /* External reference */
                        Local3 = TP1T /* External reference */
                    }
                    Case (0x02)
                    {
                        Local0 = (TP2D >> One)
                        Local0 &= 0x03
                        Local1 = (TP2D & One)
                        Local2 = TP2P /* External reference */
                        Local3 = TP2T /* External reference */
                    }
                    Case (0x03)
                    {
                        Local0 = (TP3D >> One)
                        Local0 &= 0x03
                        Local1 = (TP3D & One)
                        Local2 = TP3P /* External reference */
                        Local3 = TP3T /* External reference */
                    }
                    Case (0x04)
                    {
                        Local0 = (TP4D >> One)
                        Local0 &= 0x03
                        Local1 = (TP4D & One)
                        Local2 = TP4P /* External reference */
                        Local3 = TP4T /* External reference */
                    }
                    Case (0x05)
                    {
                        Local0 = (TP5D >> One)
                        Local0 &= 0x03
                        Local1 = (TP5D & One)
                        Local2 = TP5P /* External reference */
                        Local3 = TP5T /* External reference */
                    }
                    Case (0x06)
                    {
                        Local0 = (TP6D >> One)
                        Local0 &= 0x03
                        Local1 = (TP6D & One)
                        Local2 = TP6P /* External reference */
                        Local3 = TP6T /* External reference */
                    }
                    Case (0x07)
                    {
                        Local0 = (TP7D >> One)
                        Local0 &= 0x03
                        Local1 = (TP7D & One)
                        Local2 = TP7P /* External reference */
                        Local3 = TP7T /* External reference */
                    }
                    Case (0x08)
                    {
                        Local0 = (TP8D >> One)
                        Local0 &= 0x03
                        Local1 = (TP8D & One)
                        Local2 = TP8P /* External reference */
                        Local3 = TP8T /* External reference */
                    }
                    Case (0x09)
                    {
                        Local0 = (TP9D >> One)
                        Local0 &= 0x03
                        Local1 = (TP9D & One)
                        Local2 = TP9P /* External reference */
                        Local3 = TP9T /* External reference */
                    }
                    Case (0x0A)
                    {
                        Local0 = (TPAD >> One)
                        Local0 &= 0x03
                        Local1 = (TPAD & One)
                        Local2 = TPAP /* External reference */
                        Local3 = TPAT /* External reference */
                    }
                    Default
                    {
                        Local0 = 0xFF
                        Local1 = Zero
                        Local2 = Zero
                        Local3 = Zero
                    }

                }

                If ((Local0 == Zero))
                {
                    Return (Local2)
                }
                ElseIf (((Local0 == One) || ((Local0 == 0x02) || (Local0 == 
                    0x03))))
                {
                    If ((Local1 == One))
                    {
                        Return (Local2)
                    }
                    Else
                    {
                        Return (Local3)
                    }
                }
                Else
                {
                    Return (Zero)
                }
            }

            Method (TPLD, 2, Serialized)
            {
                Name (PCKG, Package (0x01)
                {
                    Buffer (0x10){}
                })
                CreateField (DerefOf (PCKG [Zero]), Zero, 0x07, REV)
                REV = One
                CreateField (DerefOf (PCKG [Zero]), 0x40, One, VISI)
                VISI = Arg0
                CreateField (DerefOf (PCKG [Zero]), 0x57, 0x08, GPOS)
                GPOS = Arg1
                CreateField (DerefOf (PCKG [Zero]), 0x4A, 0x04, SHAP)
                SHAP = One
                CreateField (DerefOf (PCKG [Zero]), 0x20, 0x10, WID)
                WID = 0x08
                CreateField (DerefOf (PCKG [Zero]), 0x30, 0x10, HGT)
                HGT = 0x03
                Return (PCKG) /* \_SB_.UBTC.TPLD.PCKG */
            }

            Method (TUPC, 3, Serialized)
            {
                Name (PCKG, Package (0x04)
                {
                    One, 
                    Zero, 
                    Zero, 
                    Zero
                })
                PCKG [Zero] = Arg0
                PCKG [One] = Arg1
                PCKG [0x02] = Arg2
                Return (PCKG) /* \_SB_.UBTC.TUPC.PCKG */
            }

            Method (GPLD, 2, Serialized)
            {
                Name (PCKG, Package (0x01)
                {
                    Buffer (0x10){}
                })
                CreateField (DerefOf (PCKG [Zero]), Zero, 0x07, REV)
                REV = 0x02
                CreateField (DerefOf (PCKG [Zero]), 0x07, One, RGB)
                RGB = One
                CreateField (DerefOf (PCKG [Zero]), 0x40, One, VISI)
                VISI = Arg0
                CreateField (DerefOf (PCKG [Zero]), 0x57, 0x08, GPOS)
                GPOS = Arg1
                Return (PCKG) /* \_SB_.UBTC.GPLD.PCKG */
            }

            Method (ITCP, 1, Serialized)
            {
                Switch (ToInteger (FTPT (Arg0)))
                {
                    Case (Package (0x03)
                        {
                            0x08, 
                            0x09, 
                            0x0A
                        }

)
                    {
                        Return (One)
                    }
                    Default
                    {
                        Return (Zero)
                    }

                }
            }

            Device (CR01)
            {
                Name (_ADR, Zero)  // _ADR: Address
                Method (_PLD, 0, NotSerialized)  // _PLD: Physical Location of Device
                {
                    Return (RUCC (One, 0x02, Zero))
                }

                Method (_UPC, 0, NotSerialized)  // _UPC: USB Port Capabilities
                {
                    Return (RUCC (One, One, TP1C))
                }
            }

            Device (CR02)
            {
                Name (_ADR, Zero)  // _ADR: Address
                Method (_PLD, 0, NotSerialized)  // _PLD: Physical Location of Device
                {
                    Return (RUCC (0x02, 0x02, Zero))
                }

                Method (_UPC, 0, NotSerialized)  // _UPC: USB Port Capabilities
                {
                    Return (RUCC (0x02, One, TP2C))
                }
            }

            OperationRegion (EMB3, SystemMemory, 0xFE108500, 0x0100)
            Field (EMB3, ByteAcc, NoLock, WriteAsZeros)
            {
                TTL0,   8, 
                TTL1,   8, 
                TTL2,   8, 
                TTL3,   8, 
                TTL4,   8, 
                TTL5,   8, 
                TTL6,   8, 
                TTL7,   8, 
                TER1,   8, 
                TER2,   8, 
                TSV1,   8, 
                TSV2,   8, 
                TCI0,   8, 
                TCI1,   8, 
                TCI2,   8, 
                TCI3,   8, 
                TGI0,   8, 
                TGI1,   8, 
                TGI2,   8, 
                TGI3,   8, 
                TGI4,   8, 
                TGI5,   8, 
                TGI6,   8, 
                TGI7,   8, 
                TGI8,   8, 
                TGI9,   8, 
                TGIA,   8, 
                TGIB,   8, 
                TGIC,   8, 
                TGID,   8, 
                TGIE,   8, 
                TGIF,   8, 
                TGO0,   8, 
                TGO1,   8, 
                TGO2,   8, 
                TGO3,   8, 
                TGO4,   8, 
                TGO5,   8, 
                TGO6,   8, 
                TGO7,   8, 
                TGO8,   8, 
                TGO9,   8, 
                TGOA,   8, 
                TGOB,   8, 
                TGOC,   8, 
                TGOD,   8, 
                TGOE,   8, 
                TGOF,   8
            }

            Method (QUCM, 0, Serialized)
            {
                If (\_SB.PC00.LPCB.EC0.ECOK)
                {
                    Acquire (\_SB.PC00.LPCB.EC0.MUT0, 0x2000)
                    P8XH (Zero, 0xF0)
                    MGI0 = TGI0 /* \_SB_.UBTC.TGI0 */
                    MGI1 = TGI1 /* \_SB_.UBTC.TGI1 */
                    MGI2 = TGI2 /* \_SB_.UBTC.TGI2 */
                    MGI3 = TGI3 /* \_SB_.UBTC.TGI3 */
                    MGI4 = TGI4 /* \_SB_.UBTC.TGI4 */
                    MGI5 = TGI5 /* \_SB_.UBTC.TGI5 */
                    MGI6 = TGI6 /* \_SB_.UBTC.TGI6 */
                    MGI7 = TGI7 /* \_SB_.UBTC.TGI7 */
                    MGI8 = TGI8 /* \_SB_.UBTC.TGI8 */
                    MGI9 = TGI9 /* \_SB_.UBTC.TGI9 */
                    MGIA = TGIA /* \_SB_.UBTC.TGIA */
                    MGIB = TGIB /* \_SB_.UBTC.TGIB */
                    MGIC = TGIC /* \_SB_.UBTC.TGIC */
                    MGID = TGID /* \_SB_.UBTC.TGID */
                    MGIE = TGIE /* \_SB_.UBTC.TGIE */
                    MGIF = TGIF /* \_SB_.UBTC.TGIF */
                    CCI0 = TCI0 /* \_SB_.UBTC.TCI0 */
                    CCI1 = TCI1 /* \_SB_.UBTC.TCI1 */
                    CCI2 = TCI2 /* \_SB_.UBTC.TCI2 */
                    CCI3 = TCI3 /* \_SB_.UBTC.TCI3 */
                    TCI0 = Zero
                    TCI3 = Zero
                    P8XH (Zero, 0xF1)
                    Release (\_SB.PC00.LPCB.EC0.MUT0)
                }
            }

            Method (_DSM, 4, Serialized)  // _DSM: Device-Specific Method
            {
                Name (OPMP, Buffer (0x18){})
                If ((Arg0 == ToUUID ("6f8398c2-7ca4-11e4-ad36-631042b5008f") /* Unknown UUID */))
                {
                    Switch (ToInteger (Arg2))
                    {
                        Case (Zero)
                        {
                            Return (Buffer (One)
                            {
                                 0x0F                                             // .
                            })
                        }
                        Case (One)
                        {
                            If (\_SB.PC00.LPCB.EC0.ECOK)
                            {
                                Acquire (\_SB.PC00.LPCB.EC0.MUT0, 0x2000)
                                TGO0 = MGO0 /* \_SB_.UBTC.MGO0 */
                                TGO1 = MGO1 /* \_SB_.UBTC.MGO1 */
                                TGO2 = MGO2 /* \_SB_.UBTC.MGO2 */
                                TGO3 = MGO3 /* \_SB_.UBTC.MGO3 */
                                TGO4 = MGO4 /* \_SB_.UBTC.MGO4 */
                                TGO5 = MGO5 /* \_SB_.UBTC.MGO5 */
                                TGO6 = MGO6 /* \_SB_.UBTC.MGO6 */
                                TGO7 = MGO7 /* \_SB_.UBTC.MGO7 */
                                TGO8 = MGO8 /* \_SB_.UBTC.MGO8 */
                                TGO9 = MGO9 /* \_SB_.UBTC.MGO9 */
                                TGOA = MGOA /* \_SB_.UBTC.MGOA */
                                TGOB = MGOB /* \_SB_.UBTC.MGOB */
                                TGOC = MGOC /* \_SB_.UBTC.MGOC */
                                TGOD = MGOD /* \_SB_.UBTC.MGOD */
                                TGOE = MGOE /* \_SB_.UBTC.MGOE */
                                TGOF = MGOF /* \_SB_.UBTC.MGOF */
                                TTL7 = CTL7 /* \_SB_.UBTC.CTL7 */
                                TTL6 = CTL6 /* \_SB_.UBTC.CTL6 */
                                TTL5 = CTL5 /* \_SB_.UBTC.CTL5 */
                                TTL4 = CTL4 /* \_SB_.UBTC.CTL4 */
                                TTL3 = CTL3 /* \_SB_.UBTC.CTL3 */
                                TTL2 = CTL2 /* \_SB_.UBTC.CTL2 */
                                TTL1 = CTL1 /* \_SB_.UBTC.CTL1 */
                                TTL0 = CTL0 /* \_SB_.UBTC.CTL0 */
                                P8XH (Zero, 0xE0)
                                Release (\_SB.PC00.LPCB.EC0.MUT0)
                            }
                        }
                        Case (0x02)
                        {
                            If (\_SB.PC00.LPCB.EC0.ECOK)
                            {
                                Acquire (\_SB.PC00.LPCB.EC0.MUT0, 0x2000)
                                MGI0 = TGI0 /* \_SB_.UBTC.TGI0 */
                                MGI1 = TGI1 /* \_SB_.UBTC.TGI1 */
                                MGI2 = TGI2 /* \_SB_.UBTC.TGI2 */
                                MGI3 = TGI3 /* \_SB_.UBTC.TGI3 */
                                MGI4 = TGI4 /* \_SB_.UBTC.TGI4 */
                                MGI5 = TGI5 /* \_SB_.UBTC.TGI5 */
                                MGI6 = TGI6 /* \_SB_.UBTC.TGI6 */
                                MGI7 = TGI7 /* \_SB_.UBTC.TGI7 */
                                MGI8 = TGI8 /* \_SB_.UBTC.TGI8 */
                                MGI9 = TGI9 /* \_SB_.UBTC.TGI9 */
                                MGIA = TGIA /* \_SB_.UBTC.TGIA */
                                MGIB = TGIB /* \_SB_.UBTC.TGIB */
                                MGIC = TGIC /* \_SB_.UBTC.TGIC */
                                MGID = TGID /* \_SB_.UBTC.TGID */
                                MGIE = TGIE /* \_SB_.UBTC.TGIE */
                                MGIF = TGIF /* \_SB_.UBTC.TGIF */
                                CCI0 = TCI0 /* \_SB_.UBTC.TCI0 */
                                CCI1 = TCI1 /* \_SB_.UBTC.TCI1 */
                                CCI2 = TCI2 /* \_SB_.UBTC.TCI2 */
                                Local0 = TCI3 /* \_SB_.UBTC.TCI3 */
                                CCI3 = Local0
                                If ((Local0 != Zero))
                                {
                                    TCI3 = Zero
                                }

                                TCI0 = Zero
                                P8XH (Zero, 0xD0)
                                Release (\_SB.PC00.LPCB.EC0.MUT0)
                            }
                        }
                        Case (0x03)
                        {
                            Return (XDCE) /* External reference */
                        }
                        Case (0x04)
                        {
                            Return (UDRS) /* External reference */
                        }
                        Case (0x05)
                        {
                            If ((UCMS == 0x02))
                            {
                                Return (Buffer (One)
                                {
                                     0x01                                             // .
                                })
                            }
                            Else
                            {
                                Return (Buffer (One)
                                {
                                     0x00                                             // .
                                })
                            }
                        }

                    }
                }

                Return (Buffer (One)
                {
                     0x00                                             // .
                })
            }
        }
    }
}

