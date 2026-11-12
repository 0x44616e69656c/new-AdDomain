@{
    FormatVersion = 1
    Project = 'new-AdDomain'
    Releases = @{
        '1.0' = @{
            Tag = 'v1.0'
            HeaderVersion = '1.0.0'
            Settings = @{
                CaCommonName = @{ Constant = 'Lab-Root-CA' }
                CaDatabasePath = @{ Constant = 'C:\Windows\system32\CertLog' }
                CaHashAlgorithm = @{ Constant = 'SHA256' }
                CaKeyLength = @{ Constant = 2048 }
                CaLogPath = @{ Constant = 'C:\Windows\system32\CertLog' }
                CaValidityYears = @{ Constant = 5 }
                ComputerCount = @{ Constant = 0 }
                DnsForwarders = @{ Constant = @('1.1.1.1', '8.8.8.8') }
                DomainMode = @{ Constant = 'WinThreshold' }
                DomainName = @{ Constant = 'lab.local' }
                DsrmPassword = @{ Sha256 = 'a8c29a3996d7489586622f2a703a7357c13b340acfc70855319a9dd066804bf2' }
                ForestMode = @{ Constant = 'WinThreshold' }
                GroupCount = @{ Constant = 50 }
                LaptopPrefix = @{ Constant = 'LAP' }
                LockoutDurationMinutes = @{ Constant = 30 }
                LockoutThreshold = @{ Constant = 5 }
                MaxCompanyCount = @{ Constant = 5 }
                MaxDA = @{ Constant = 10 }
                MaxGroupMembers = @{ Constant = 10 }
                MaxGroupNestingDepth = @{ Constant = 3 }
                MaxPasswordAgeDays = @{ Constant = 90 }
                MinCompanyCount = @{ Constant = 1 }
                MinDA = @{ Constant = 2 }
                MinGroupMembers = @{ Constant = 2 }
                MinPasswordLength = @{ Constant = 15 }
                NetBIOSName = @{ Constant = 'LAB' }
                NtpServers = @{ Constant = @('time.windows.com') }
                PasswordHistoryCount = @{ Constant = 24 }
                PasswordLength = @{ Constant = 20 }
                PctDisabled = @{ Constant = 5 }
                PctLocked = @{ Constant = 2 }
                PctPwExpired = @{ Constant = 5 }
                PctPwNeverExpires = @{ Constant = 10 }
                PctRemoteUsers = @{ Constant = 30 }
                PctSmartcard = @{ Constant = 3 }
                PrimarySiteName = @{ Constant = 'Lab-HQ' }
                PrimarySubnet = @{ Constant = '10.0.0.0/24' }
                RandomSeed = @{ Constant = 0 }
                RequiredOSBuild = @{ Constant = 26100 }
                ServerPrefix = @{ Constant = 'SRV' }
                UpnPattern = @{ Constant = 'firstlast' }
                UserCount = @{ Constant = 1000 }
                WorkstationPrefix = @{ Constant = 'WK' }
            }
            Csv = @{
                'cities.csv' = '4f85c59249a6bb51b51bc75b05bc215fbd1259ea32788bfaf875333271717c84'
                'companies.csv' = '95dabe351ea51375f0880b698f4846a9b33851a178f4b6064036eac3cd25426e'
                'computers.csv' = 'e508f5dcb591bbc0e52cb5e03714a22126b7b537f92307420500eb75d4a501a9'
                'departments.csv' = '424375366977ab0440157b178a694d930855534ad13c4c400ae6670814cfd122'
                'first.csv' = 'eb1aa4c9af74d9060f558808a2b065f7e2b5c1fb91ee6e8a0fa861e64aac7720'
                'last.csv' = '7059100f83f41fe15c9e557a0beca671c03ec908a3cc7763f88edfcffe3451c8'
                'offices.csv' = '3b539980ee27c9d2bff54e8d5a9543c3138f4dfb361b8154aa1ac2ffbb7bcc55'
                'serviceaccounts.csv' = 'bb710d78ada9d71e2f4268a7e5823a5d9ed21c3311984a4a950ff47c4780ce05'
                'streets.csv' = '585314d89e1aae65564d33ae16ccf57d38e44e73723f7b4ede2d095ed0aadfef'
                'titles.csv' = '85e125ef248ee5a44be6db26ad9fcffb48e0053375f060b17dc8f46ad1350e57'
                'words.csv' = 'e5382b945cde449cbb581e5ede1764cb07a08df35ac54de7db2e1ba97abb16c8'
            }
        }
        '2.0.0' = @{
            Tag = 'v2.0.0'
            HeaderVersion = '2.0.0'
            Settings = @{
                CaCommonName = @{ Constant = 'Lab-Root-CA' }
                CaDatabasePath = @{ Constant = 'C:\Windows\system32\CertLog' }
                CaHashAlgorithm = @{ Constant = 'SHA256' }
                CaKeyLength = @{ Constant = 2048 }
                CaLogPath = @{ Constant = 'C:\Windows\system32\CertLog' }
                CaValidityYears = @{ Constant = 5 }
                ComputerCount = @{ Constant = 0 }
                DnsForwarders = @{ Constant = @('1.1.1.1', '8.8.8.8') }
                DomainMode = @{ Constant = 'WinThreshold' }
                DomainName = @{ Constant = 'lab.test' }
                DsrmPassword = @{ Sha256 = 'a8c29a3996d7489586622f2a703a7357c13b340acfc70855319a9dd066804bf2' }
                ForestMode = @{ Constant = 'WinThreshold' }
                GroupCount = @{ Constant = 50 }
                LaptopPrefix = @{ Constant = 'LAP' }
                LockoutDurationMinutes = @{ Constant = 30 }
                LockoutThreshold = @{ Constant = 5 }
                MaxCompanyCount = @{ Constant = 5 }
                MaxDA = @{ Constant = 10 }
                MaxGroupMembers = @{ Constant = 10 }
                MaxGroupNestingDepth = @{ Constant = 3 }
                MaxPasswordAgeDays = @{ Constant = 90 }
                MinCompanyCount = @{ Constant = 1 }
                MinDA = @{ Constant = 2 }
                MinGroupMembers = @{ Constant = 2 }
                MinPasswordLength = @{ Constant = 15 }
                NetBIOSName = @{ Constant = 'LAB' }
                NtpServers = @{ Constant = @('time.windows.com') }
                PasswordHistoryCount = @{ Constant = 24 }
                PasswordLength = @{ Constant = 20 }
                PctDisabled = @{ Constant = 5 }
                PctLocked = @{ Constant = 2 }
                PctPwExpired = @{ Constant = 5 }
                PctPwNeverExpires = @{ Constant = 10 }
                PctRemoteUsers = @{ Constant = 30 }
                PctSmartcard = @{ Constant = 3 }
                PrimarySiteName = @{ Constant = 'Lab-HQ' }
                PrimarySubnet = @{ Constant = 'Auto' }
                RandomSeed = @{ Constant = 0 }
                RequiredOSBuild = @{ Constant = 26100 }
                ServerPrefix = @{ Constant = 'SRV' }
                UpnPattern = @{ Constant = 'firstlast' }
                UserCount = @{ Constant = 1000 }
                WorkstationPrefix = @{ Constant = 'WK' }
            }
            Csv = @{
                'cities.csv' = '4f85c59249a6bb51b51bc75b05bc215fbd1259ea32788bfaf875333271717c84'
                'companies.csv' = '95dabe351ea51375f0880b698f4846a9b33851a178f4b6064036eac3cd25426e'
                'computers.csv' = 'e508f5dcb591bbc0e52cb5e03714a22126b7b537f92307420500eb75d4a501a9'
                'departments.csv' = '424375366977ab0440157b178a694d930855534ad13c4c400ae6670814cfd122'
                'first.csv' = 'eb1aa4c9af74d9060f558808a2b065f7e2b5c1fb91ee6e8a0fa861e64aac7720'
                'last.csv' = '7059100f83f41fe15c9e557a0beca671c03ec908a3cc7763f88edfcffe3451c8'
                'offices.csv' = '3b539980ee27c9d2bff54e8d5a9543c3138f4dfb361b8154aa1ac2ffbb7bcc55'
                'serviceaccounts.csv' = '54d83411d526e86113b520d681dd780f996234a441b6cc525fc36a773ac26373'
                'streets.csv' = '585314d89e1aae65564d33ae16ccf57d38e44e73723f7b4ede2d095ed0aadfef'
                'titles.csv' = '85e125ef248ee5a44be6db26ad9fcffb48e0053375f060b17dc8f46ad1350e57'
                'words.csv' = 'e5382b945cde449cbb581e5ede1764cb07a08df35ac54de7db2e1ba97abb16c8'
            }
        }
        '2.1.0' = @{
            Tag = 'v2.1.0'
            HeaderVersion = '2.1.0'
            Settings = @{
                CaCommonName = @{ Constant = 'Lab-Root-CA' }
                CaDatabasePath = @{ Constant = 'C:\Windows\system32\CertLog' }
                CaHashAlgorithm = @{ Constant = 'SHA256' }
                CaKeyLength = @{ Constant = 2048 }
                CaLogPath = @{ Constant = 'C:\Windows\system32\CertLog' }
                CaValidityYears = @{ Constant = 5 }
                ComputerCount = @{ Constant = 0 }
                DnsForwarders = @{ Constant = @('1.1.1.1', '8.8.8.8') }
                DomainMode = @{ Constant = 'WinThreshold' }
                DomainName = @{ Constant = 'lab.test' }
                DsrmPassword = @{ Sha256 = 'a8c29a3996d7489586622f2a703a7357c13b340acfc70855319a9dd066804bf2' }
                ForestMode = @{ Constant = 'WinThreshold' }
                GroupCount = @{ Constant = 50 }
                LaptopPrefix = @{ Constant = 'LAP' }
                LockoutDurationMinutes = @{ Constant = 30 }
                LockoutThreshold = @{ Constant = 5 }
                MaxCompanyCount = @{ Constant = 5 }
                MaxDA = @{ Constant = 10 }
                MaxGroupMembers = @{ Constant = 10 }
                MaxGroupNestingDepth = @{ Constant = 3 }
                MaxPasswordAgeDays = @{ Constant = 90 }
                MinCompanyCount = @{ Constant = 1 }
                MinDA = @{ Constant = 2 }
                MinGroupMembers = @{ Constant = 2 }
                MinPasswordLength = @{ Constant = 14 }
                NetBIOSName = @{ Constant = 'LAB' }
                NtpServers = @{ Constant = @('time.windows.com') }
                PasswordHistoryCount = @{ Constant = 24 }
                PasswordLength = @{ Constant = 20 }
                PctDisabled = @{ Constant = 5 }
                PctLocked = @{ Constant = 2 }
                PctPwExpired = @{ Constant = 5 }
                PctPwNeverExpires = @{ Constant = 10 }
                PctRemoteUsers = @{ Constant = 30 }
                PctSmartcard = @{ Constant = 3 }
                PrimarySiteName = @{ Constant = 'Lab-HQ' }
                PrimarySubnet = @{ Constant = 'Auto' }
                RandomSeed = @{ Constant = 0 }
                RequiredOSBuild = @{ Constant = 26100 }
                ServerPrefix = @{ Constant = 'SRV' }
                UpnPattern = @{ Constant = 'firstlast' }
                UserCount = @{ Constant = 1000 }
                WorkstationPrefix = @{ Constant = 'WK' }
            }
            Csv = @{
                'cities.csv' = '4f85c59249a6bb51b51bc75b05bc215fbd1259ea32788bfaf875333271717c84'
                'companies.csv' = '95dabe351ea51375f0880b698f4846a9b33851a178f4b6064036eac3cd25426e'
                'computers.csv' = 'e508f5dcb591bbc0e52cb5e03714a22126b7b537f92307420500eb75d4a501a9'
                'departments.csv' = '424375366977ab0440157b178a694d930855534ad13c4c400ae6670814cfd122'
                'first.csv' = 'eb1aa4c9af74d9060f558808a2b065f7e2b5c1fb91ee6e8a0fa861e64aac7720'
                'last.csv' = '7059100f83f41fe15c9e557a0beca671c03ec908a3cc7763f88edfcffe3451c8'
                'offices.csv' = '3b539980ee27c9d2bff54e8d5a9543c3138f4dfb361b8154aa1ac2ffbb7bcc55'
                'serviceaccounts.csv' = '54d83411d526e86113b520d681dd780f996234a441b6cc525fc36a773ac26373'
                'streets.csv' = '585314d89e1aae65564d33ae16ccf57d38e44e73723f7b4ede2d095ed0aadfef'
                'titles.csv' = '85e125ef248ee5a44be6db26ad9fcffb48e0053375f060b17dc8f46ad1350e57'
                'words.csv' = 'e5382b945cde449cbb581e5ede1764cb07a08df35ac54de7db2e1ba97abb16c8'
            }
        }
    }
}
