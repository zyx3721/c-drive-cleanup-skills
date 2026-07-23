$skillPath = Join-Path $PSScriptRoot '..\SKILL.md'
$skill = Get-Content -LiteralPath $skillPath -Raw

Describe 'C drive cleanup report contract' {
    It 'requires full paths in every reported candidate row' {
        $skill | Should Match '表头必须包含“路径”'
        $skill | Should Match '完整 `Path`'
    }

    It 'forbids category-only aggregation without actual paths' {
        $skill | Should Match '不得把多个目录合并成只有'
        $skill | Should Match '不得省略盘符'
    }
}
