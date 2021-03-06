########################################################################################################################
#
# File:       Get-ValueFromRegFile.ps1
# Author:     Chris Coffin (gmail: cpcgithub)
# Repository: https://github.com/cpcoffin/PS-Registry
#
########################################################################################################################

#Requires -Version 3

<#
.SYNOPSIS
Reads registry values from a .reg file

.DESCRIPTION
This function parses .reg files and returns objects representing the values with fields Hive, Key, ValueName, Type, and
Data. Only values are returned (keys with no values specified are ignored).
#>

Function Get-ValueFromRegFile
{
    Param([Parameter(Mandatory, ValueFromPipeline)]
          [string]$FileName
         )
         
    #region Helper functions
    
    # Returns hash table with hive and path of the new key specified. Returns $null if $Line does not specify a key
    Function Parse-Key($Line)
    {
        If ($Line -match '\[(HKEY_(CLASSES_ROOT|CURRENT_USER|LOCAL_MACHINE|USERS|CURRENT_CONFIG))\\(.*)\]$')
        {
            return @{'Hive' = $Matches[1]; 'Key' = $Matches[3]}
        }
        Else
        {
            return $Null
        }
    }
    
    # Returns true if and only if $str contains an odd number of unescaped quotes
    Function Test-ContainsExtraQuote($str)
    {
        (($str.Replace('\\','').Replace('\"','').Split('"').Count-1)%2) -eq 1
    }

    # Returns position of first '=' that is not contained in quotes, or -1 if there is none
    Function Find-NameDataSeparator($str)
    {
        If ($str.Contains('='))
        {
            $idx = $str.IndexOf('=')
            While (Test-ContainsExtraQuote $str.Substring(0,$idx))
            {
                $nextEq = $str.Substring($idx+1).IndexOf('=')
                If ($nextEq -eq -1)
                {
                    return -1
                }
                $idx += $nextEq + 1
            }
            return $idx
        }
        Else
        {
            return -1
        }
    }
    
    # Unescapes quotes and backslashes. Strings with an unescaped backslash throw an error.
    Function Unescape-String($str)
    {
        $Escape = $False
        $ret = ''
        For ($i=0; $i -lt $str.Length; $i++)
        {
            If ($Escape)
            {
                If ($str[$i] -in @('"','\'))
                {
                    $ret += $str[$i]
                    $Escape = $False
                }
                Else
                {
                    throw 'Failed to unescape string'
                }
            }
            ElseIf ($str[$i] -eq '\')
            {
                $Escape = $True
            }
            Else
            {
                $ret += $str[$i]
            }
        }
        return $ret
    }
    
    # Accepts a comma-delimited list of hex values and returns byte array
    Function Parse-BinaryData($Data)
    {
        Try
        {
            If ($Data[-1] -eq ',')
            {
                $Data = $Data.Substring(0,$Data.Length-1)
            }
            $ret = [byte[]]@()
            ($Data -Split ',') | ForEach {
                $ret += [byte]"0x$_"
            }
        }
        Catch
        {
            throw 'Failed to parse binary data'
        }
        return $ret
    }
    
    # Gets name, (first line of) data and type of a value - throws error if a value can't be parsed
    Function Parse-Value($Line)
    {
        $sep = Find-NameDataSeparator $Line
        If ($sep -eq -1) { return $null }
        
        # Parse value name
        $Name = $Line.Substring(0,$sep)
        If (($Name[0] -ne '"') -or ($Name[-1] -ne '"'))
        {
            throw 'Failed to parse value name'
        }
        $Name = $Name.Substring(1,$Name.Length-2)
        
        $Data = $Line.Substring($sep+1)
        # Parse string data
        If ($Data[0] -eq '"')
        {
            $Type = 'REG_SZ'
            If (Test-ContainsExtraQuote $Data)
            {
                $Data = $Data.Substring(1)
                $Data += "`r`n"
                $MoreData = $True
            }
            Else
            {
                $Data = $Data.Substring(1, $Data.Length-2)
                $MoreData = $False
            }
        }
        # Other data types
        Else
        {
            $sep = $Data.IndexOf(':')
            If ($sep -eq -1)
            {
                throw 'Failed to determine data type'
            }
            $Prefix = $Data.Substring(0,$sep)
            $Data = $Data.Substring($sep+1)
            If ($Data[-1] -eq '\')
            {
                $MoreData = $True
                $Data = $Data.Substring(0,$Data.Length-1)
            }
            Else
            {
                $MoreData = $False
            }
            If ($Prefix -eq 'dword')
            {
                If ($MoreData)
                {
                    throw 'Failed to parse DWORD value'
                }
                $Type = 'REG_DWORD'
                $Data = [int]"0x$Data"
            }
            Else
            {
                $HexTypes = @{'hex'    = 'REG_BINARY';
                              'hex(0)' = 'REG_NONE';
                              'hex(2)' = 'REG_EXPAND_SZ';
                              'hex(7)' = 'REG_MULTI_SZ';
                              'hex(b)' = 'REG_QWORD'}
                If ($Prefix -notin $HexTypes.Keys)
                {
                    throw 'Unknown data type'
                }
                $Type = $HexTypes[$Prefix]
                $Data = Parse-BinaryData $Data
            }
        }
        return [pscustomobject]@{'ValueName' = $Name; 'Type' = $Type; 'Data' = $Data; 'MoreData' = $MoreData}
    }
    
    # Accepts byte array representing null-terminated unicode string, returns a string
    Function Parse-BinaryString($Bytes)
    {
        If (($Bytes.Length % 2) -ne 0)
        {
            throw 'Missing byte in binary string'
        }
        If (($Bytes.Length -lt 2) -or (($Bytes[-1] + $Bytes[-2]) -ne 0))
        {
            throw 'Bad end delimiter on binary string'
        }
        $NullTerminatedString = [System.Text.Encoding]::Unicode.GetString($Bytes)
        return $NullTerminatedString.Substring(0, $NullTerminatedString.Length-1)
    }
    
    # Performs final value parsing, removes the MoreData field and outputs
    Function Finalize-Value($Value)
    {
        If ($Value.Type -eq 'REG_QWORD')
        {
            $PositionMultiplier = 1
            $LongValue = [long]0
            ForEach ($Byte In $Value.Data)
            {
                $LongValue += ($Byte * $PositionMultiplier)
                $PositionMultiplier *= 0x100
            }
            $Value.Data = $LongValue
        }
        ElseIf ($Value.Type -eq 'REG_EXPAND_SZ')
        {
            $Value.Data = Parse-BinaryString $Value.Data
        }
        ElseIf ($Value.Type -eq 'REG_MULTI_SZ')
        {
            If (($Value.Data.Length -lt 2) -or (($Value.Data[-1]+ $Value.Data[-2]) -ne 0))
            {
                throw 'Bad end delimiter on MULTI_SZ'
            }
            $StringArrayValue = @()
            $Bytes = @()
            For ($i = 0; $i -lt ($Value.Data.Length - 2); $i += 2)
            {
                $Bytes += $Value.Data[$i]
                $Bytes += $Value.Data[$i+1]
                If (($Value.Data[$i] + $Value.Data[$i+1]) -eq 0)
                {
                    $StringArrayValue += @(Parse-BinaryString $Bytes)
                    $Bytes = @()
                }
            }
            $Value.Data = $StringArrayValue
        }
        ElseIf ($Value.Type -eq 'REG_SZ')
        {
            $Value.Data = Unescape-String $Value.Data
        }
        $Value = $Value | Add-Member -NotePropertyName 'Hive' -NotePropertyValue $Hive -PassThru | 
                          Add-Member -NotePropertyName 'Key' -NotePropertyValue $Key -PassThru |
                          Select Hive,Key,ValueName,Type,Data
        $Value.PSObject.TypeNames.Insert(0,'RegistryEntry')
        $Value
    }
    #endregion Helper functions
    
    #region Main state machine for parsing .reg file
    $State = 'start'
    $LineNumber = 0
    $Key = $Null
    $Hive = $Null
    $Value = $Null
    Get-Content $FileName | ForEach {
        $LineNumber++
        $Line = $_.Trim()
        $UntrimmedLine = $_
        Try
        {
            Switch ($State)
            {
                'start'
                {
                    If ($Line)
                    {
                        If ($Line -ne 'Windows Registry Editor Version 5.00')
                        {
                            throw 'Invalid header'
                        }
                        Else
                        {
                            $State = 'first_key'
                        }
                    }
                }
                'first_key'
                {
                    If ($Line)
                    {
                        $NewKey = Parse-Key $Line
                        If ($NewKey -eq $null)
                        {
                            throw 'Expected new key'
                        }
                        $Hive = $NewKey.Hive
                        $Key = $NewKey.Key
                        $State = 'next_item'
                    }
                }
                'next_item'
                {
                    If ($Line)
                    {
                        # Check for new key
                        $NewKey = Parse-Key $Line
                        If ($NewKey)
                        {
                            $Hive = $NewKey.Hive
                            $Key = $NewKey.Key
                        }
                        # Otherwise check for value
                        Else
                        {
                            $Value = Parse-Value $Line
                            If ($Value.MoreData)
                            {
                                If ($Value.Type -eq 'REG_SZ')
                                {
                                    $State = 'reading_string'
                                }
                                Else
                                {
                                    $State = 'reading_bytes'
                                }
                            }
                            Else
                            {
                                Finalize-Value $Value
                            }
                        }
                    }
                }
                'reading_string'
                {
                    If (Test-ContainsExtraQuote $UntrimmedLine)
                    {
                        $Line = $UntrimmedLine.TrimEnd()
                        If ($Line[-1] -ne '"')
                        {
                            throw 'Data past end of string'
                        }
                        $Line = $Line.Substring(0,$Line.Length-1)
                        $Value.Data += $Line
                        Finalize-Value $Value
                        $State = 'next_item'
                    }
                    Else
                    {
                        $Line = $UntrimmedLine
                        $Value.Data += "$Line`r`n"
                    }
                }
                'reading_bytes'
                {
                    If ($Line[-1] -eq '\')
                    {
                        $Line = $Line.Substring(0, $Line.Length-1)
                        $Value.Data += Parse-BinaryData $Line
                    }
                    Else
                    {
                        $Value.Data += Parse-BinaryData $Line
                        Finalize-Value $Value
                        $State = 'next_item'
                    }
                }
                default
                {
                    throw 'Bad state'
                }
            }
        }
        Catch
        {
            throw "Parsing $FileName failed on line number $LineNumber <$Line> with error: $_"
        }
    }
    #endregion
}
