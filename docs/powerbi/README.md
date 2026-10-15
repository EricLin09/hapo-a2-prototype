# HAPO Power BI 报表：操作清单

目标：在 Windows 的 Power BI Desktop 里，把三个用例（UC1–UC3）和测试证据做成报表，**数据来自已经测试过的 PostgreSQL 数据仓库**。数据库、ETL 和 50 项测试都不变，Power BI 只替换展示层。

全部数值都是合成数据。做完后按第 7 节逐项核对，数字必须和静态仪表板完全一致。

---

## 0. 选一条路线

| 路线 | 适合 | 优点 |
|---|---|---|
| **A. 直连 PostgreSQL（推荐）** | Windows 上能装 Docker 和课程实验环境 | Power BI 直接读数据仓库的报表视图，最能说明"原型接入了 Power BI" |
| **B. 导入 CSV** | 不想在 Windows 上装 Docker，或 A 卡住了 | 不需要数据库，`data/` 文件夹里的 CSV 拿来就能用 |

两条路线读到的数据完全一样，后面第 3 到第 8 步也一样。

---

## 1A. 路线 A：在 Windows 上准备数据库

1. 安装并打开 Docker Desktop，在课程实验环境文件夹（`advanced-database-lab`）里运行 `docker compose up -d`。
2. 在 PowerShell 里进入本仓库根目录，依次运行：

```powershell
docker exec student-postgres psql -U student -d postgres -c "CREATE DATABASE hapo_a2"
docker cp database/hapo_a2.sql student-postgres:/tmp/hapo_a2.sql
docker exec student-postgres psql -q -U student -d hapo_a2 -v ON_ERROR_STOP=1 -f /tmp/hapo_a2.sql
```

3. 检查：下面这条命令应该返回 `30.00`。

```powershell
docker exec student-postgres psql -U student -d hapo_a2 -Atc "SELECT rent_to_income_pct FROM reporting.vw_dashboard_uc1 WHERE lga_code = '16260' AND quarter = '2025-Q1'"
```

## 2A. 路线 A：在 Power BI 里连接

1. **Home → Get data → More… → Database → PostgreSQL database**。
2. Server 填 `localhost`，Database 填 `hapo_a2`，Data Connectivity mode 选 **Import**。
3. 凭据选 **Database** 标签，用户名和密码都填 `student`。
4. 如果提示无法用加密连接，选择不加密继续。实验环境的 PostgreSQL 没开 SSL，这是正常的。也可以在 File → Options and settings → Data source settings → Edit Permissions 里取消勾选 "Encrypt connections"。
5. 在 Navigator 里勾选这 6 个对象：
   - `reporting.vw_dashboard_uc1`、`reporting.vw_dashboard_uc2`、`reporting.vw_dashboard_uc3`
   - `dw.dim_geography`
   - `control.test_run`、`control.test_result`
6. 再用 **Get data → PostgreSQL database** 加两个查询。连接方式同上，在 **Advanced options → SQL statement** 里分别填：

```sql
SELECT reporting.dashboard_fingerprint() AS current_fingerprint
```

```sql
SELECT r.source_system, r.rule_code, v.rule_description, r.source_column, r.raw_record::text AS raw_record
FROM curated.rejected_row r JOIN curated.validation_rule v USING (rule_code)
ORDER BY r.rejected_row_id
```

## 1B / 2B. 路线 B：导入 CSV

**Home → Get data → Text/CSV**，依次导入 `docs/powerbi/data/` 里的 `uc1`、`uc2`、`uc3`、`dim_geography`、`test_run`、`test_result`、`current_fingerprint`、`rejected_row` 这 8 个 CSV（`lineage.csv` 可选）。

这些 CSV 是 12 Oct 那次构建（50/50 通过）导出的。布尔值已经写成 TRUE/FALSE，空单元格表示没有数据，不是 0。

---

## 3. 重命名表，检查类型（Transform data）

在 Power Query 里把查询重命名成下面这些名字，第 5 步的 DAX 就靠这些名字：

`uc1` · `uc2` · `uc3` · `dim_geography` · `test_run` · `test_result` · `current_fingerprint` · `rejected_row`

检查数据类型：
- **所有表的 `lga_code` 都必须是 Text。** 路线 B 的 CSV 会被自动识别成 Whole Number，要手动改成 Text。
- `quarter_start`、`month_start` 是 Date。
- `is_complete_supply_year`、`current_flag` 是 True/False。

点 **Close & Apply**。

## 4. 建模（Model view 和 Data view）

**关系**：`dim_geography[lga_code]` 一对多连到 `uc1[lga_code]`、`uc2[lga_code]`、`uc3[lga_code]`，Cross filter direction 选 Single。如果 Power BI 自动建了别的关系，比如 uc 表之间互相连，删掉。

**排序**：在 Data view 选中列，然后 **Column tools → Sort by column**：
- `uc1[quarter]` 按 `uc1[quarter_start]`
- `uc2[financial_year_label]` 按 `uc2[financial_year]`
- `uc3[month_label]` 按 `uc3[month_start]`

**防止错误求和（最重要）**：Power BI 默认会把数字列加总。比例和中位数一旦加总就是错的，这正是我们设计里明确禁止的。
- 把 `uc1`、`uc2` 里所有数值列的 **Summarization** 设成 **Don't summarize**。
- 然后在 Report view 里右键这些原始数值列 → **Hide in report view**。
- 做图时**只用第 5 步的度量值**。这些度量值只在恰好对应一个 LGA 和一个时期时才返回数值，否则返回空，从机制上杜绝错误加总。

## 5. 度量值（Home → New measure，逐条粘贴）

放在 `uc1` 表：

```DAX
Rent to income % =
IF ( HASONEVALUE ( uc1[lga_code] ) && HASONEVALUE ( uc1[quarter] ),
     SELECTEDVALUE ( uc1[rent_to_income_pct] ) )
```

```DAX
Median weekly rent =
IF ( HASONEVALUE ( uc1[lga_code] ) && HASONEVALUE ( uc1[quarter] ),
     SELECTEDVALUE ( uc1[median_weekly_rent] ) )
```

```DAX
Rent change % =
IF ( HASONEVALUE ( uc1[lga_code] ) && HASONEVALUE ( uc1[quarter] ),
     SELECTEDVALUE ( uc1[rent_change_pct] ) )
```

放在 `uc2` 表：

```DAX
Population growth % =
IF ( HASONEVALUE ( uc2[lga_code] ) && HASONEVALUE ( uc2[financial_year] ),
     SELECTEDVALUE ( uc2[population_growth_pct] ) )
```

```DAX
DA approvals per 1,000 =
IF ( HASONEVALUE ( uc2[lga_code] ) && HASONEVALUE ( uc2[financial_year] ),
     SELECTEDVALUE ( uc2[da_approved_per_1000_residents] ) )
```

放在 `uc3` 表（只在选定一个 LGA 时显示，缺失的月份保持空白）：

```DAX
Lodged dwellings = IF ( HASONEVALUE ( uc3[lga_code] ), SUM ( uc3[lodged_dwellings] ) )
```

```DAX
DA approved dwellings = IF ( HASONEVALUE ( uc3[lga_code] ), SUM ( uc3[da_approved_dwellings] ) )
```

```DAX
CC approved dwellings = IF ( HASONEVALUE ( uc3[lga_code] ), SUM ( uc3[cc_approved_dwellings] ) )
```

放在 `test_result` 表。这几条把原型的"VERIFIED 规则"搬进 Power BI：最近一次测试全部通过，**并且**导入的数据指纹和测试时一致，才显示 VERIFIED。

```DAX
Tests total =
VAR r = MAX ( test_run[run_id] )
RETURN CALCULATE ( COUNTROWS ( test_result ), test_result[run_id] = r )
```

```DAX
Tests passed =
VAR r = MAX ( test_run[run_id] )
RETURN CALCULATE ( COUNTROWS ( test_result ), test_result[run_id] = r, test_result[status] = "PASS" )
```

```DAX
Tested fingerprint =
VAR r = MAX ( test_run[run_id] )
RETURN LOOKUPVALUE ( test_run[report_fingerprint], test_run[run_id], r )
```

```DAX
Verification status =
IF ( [Tests total] > 0
       && [Tests passed] = [Tests total]
       && [Tested fingerprint] = SELECTEDVALUE ( current_fingerprint[current_fingerprint] ),
     "VERIFIED · " & [Tests passed] & "/" & [Tests total] & " PASS",
     "NOT VERIFIED" )
```

给比例类度量值设格式：选中度量值 → **Measure tools → Decimal places = 2**。

## 6. 报表页面

**第 1 页 · Overview**
- Card：`Verification status`
- Card：`Tested fingerprint`
- Text box：说明全部是合成数据，所有数值不代表 NSW 的真实情况。

**第 2 页 · UC1 Rental pressure**
- Slicer：`uc1[quarter]`，单选，选 2026-Q2。
- Clustered bar chart：Y 轴 `dim_geography[lga_name]`，X 轴 `[Rent to income %]`，按数值降序。
- Slicer：`dim_geography[lga_name]`，单选，选 Parramatta。
- Line chart：X 轴 `uc1[quarter]`，Y 轴 `[Rent to income %]`。
- **Edit interactions**（Format → Edit interactions）：
  - 选中 LGA slicer，把柱状图设成 **None**，这样柱状图始终显示全部 LGA。
  - 选中 quarter slicer，把折线图设成 **None**，这样折线图始终显示全部季度。
- Text box：说明这是区域层面的代理指标，收入固定为 2021 年人口普查值，不等于家庭租金负担。

**第 3 页 · UC2 Population vs approvals**
- Slicer：`uc2[financial_year_label]`，单选，选 FY2024-25。
- Scatter chart：Values `dim_geography[lga_name]`，X 轴 `[Population growth %]`，Y 轴 `[DA approvals per 1,000]`，Legend `uc2[is_complete_supply_year]`。用颜色区分审批数据完整和不完整的年份。
- Table：`uc2[lga_name]`、`uc2[financial_year_label]`，visual-level filter 设为 `population_growth_pct is blank`，标题写 "Not comparable (no ERP for both years)"。
- Text box：说明审批数不等于建成住房，人口和住房的单位也不同。

**第 4 页 · UC3 Approval pipeline**
- Slicer：`dim_geography[lga_name]`，单选。
- Line chart：X 轴 `uc3[month_label]`，Y 轴放 `[Lodged dwellings]`、`[DA approved dwellings]`、`[CC approved dwellings]` 三条线。
- Text box：说明三个阶段是每月各自独立的计数，不是同一批项目在各阶段之间流转，而且没有 LGA 层面的竣工数据。

**第 5 页 · Data quality and tests**
- Card：`Verification status`
- Table：`test_result` 的 test_group、test_id、test_name、severity、status
- Table：`rejected_row` 的 source_system、rule_code、rule_description、raw_record
- （可选）Table：`lineage` 加一个 LGA slicer，展示每条事实数据能追溯到源文件的第几行。

## 7. 核对清单（全部对上才算完成）

| 位置 | 操作 | 应该看到 |
|---|---|---|
| Overview | 看 Card | `VERIFIED · 50/50 PASS`，指纹 `89cdbb230aa54b8ad6a5e25eb6b7d0e5` |
| UC1 | quarter 选 2026-Q2 | 最高是 Fairfield 40.21，其次 Sydney 40.05 |
| UC1 | LGA 选 Parramatta，看 2025-Q1 | **30.00**（600 ÷ 2,000） |
| UC2 | FY2024-25，Parramatta | 增长 **2.00**，每千人 **9.05** |
| UC2 | FY2024-25，Penrith | 2.03 / 7.90，颜色显示为 FALSE（审批数据不完整） |
| UC2 | FY2024-25 的表格 | 列出 Cumberland（人口为空，被 R06 拒绝） |
| UC2 | FY2025-26 | 散点图为空，所有 LGA 都出现在表格里（还没有 2026 年人口数据） |
| UC3 | Penrith，Mar 2025 | Lodged 157，DA 171，**CC 为空白，不是 0** |
| UC3 | Fairfield，Nov 2025 | Lodged 116，CC 84，**DA 为空白，不是 0** |
| UC1 | 不选 LGA 时看折线图 | 没有数值（度量值返回空），说明没有被错误加总 |
| Data quality | 两张表 | 50 行测试全部为 PASS；38 行被拒绝的记录 |

如果 UC3 的折线在空白月份被连了起来，看一下 X 轴是否开启了 "Show items with no data"，并确认那个点在提示框里显示为空白。关键是缺失值不能被画成 0。

## 8. 保存和交付

1. 另存为 `docs/powerbi/HAPO_PowerBI.pbix`，提交并推送到仓库。
2. **File → Export → Export to PDF**，生成报告和演示稿要用的截图。
3. 需要更新这些文档，把 "static dashboard only" 改成 "static dashboard + Power BI report"：
   - 演示稿第 13 页底部注释（"no Power BI PBIX claim"）和第 18 页（"Power BI CSV files remain optional"）
   - 报告第 3 节 Reports and Dashboards
   - Team 1 架构的 Outputs 和 trade-off 表
   - Team 2 文档第 8 节和第 11 节
