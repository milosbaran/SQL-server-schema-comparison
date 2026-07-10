To run the PowerShell 

With SQL User credentials
```powershell
.\serverSchema.ps1 -ServerInstance "SERVER-INSTANCE" -OutputFile "master-schema.json" -Username "yourlogin" -Password "yourpassword"
```

With AD credentials
```powershell
.\serverSchema.ps1 -ServerInstance "SERVER-INSTANCE" -OutputFile "master-schema.json"
```

Basic
```bash
./compare-schema-v2.sh \
  --master master-schema.json \
  --target target-schema.json
```

Rename database suffix during compare
```bash
./compare-schema-v2.sh \
  --master master-schema.json \
  --target target-schema.json \
  --rename-from "_ownName" \
  --rename-to "_alternativeName"
```

Skip dev databases
```bash
./compare-schema-v2.sh \
  --master master-schema.json \
  --target target-schema.json \
  --skip-contains "Dev"
```

Ignore column order. The same column in a different physical order will not be flagged as a difference.
```bash
./compare-schema-v2.sh \
  --master master-schema.json \
  --target target-schema.json \
  --ignore-column-order
```

Combine all
```bash
./compare-schema-v2.sh \
  --master master-schema.json \
  --target target-schema.json \
  --rename-from "_ownName" \
  --rename-to "_alternativeName" \
  --skip-contains "Dev" \
  --skip-contains "_Test" \
  --ignore-column-order
```
