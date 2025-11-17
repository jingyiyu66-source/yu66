#!/bin/bash

# 设置BIDS根目录
BIDS_ROOT="/home/xue/data/BIDS_prep"  # 请替换为实际路径

# 存储不符合要求的run信息
PROBLEMATIC_RUNS=()

# 遍历所有被试
for subject in sub-{01..10}; do
    # 遍历所有session
    for session in ses-{01..03}; do
        # 检查目录是否存在
        FUNC_DIR="$BIDS_ROOT/$subject/$session/func"
        if [ ! -d "$FUNC_DIR" ]; then
            echo "警告: $FUNC_DIR 目录不存在，跳过"
            continue
        fi
        
        # 处理所有BOLD文件
        for bold_file in "$FUNC_DIR"/*_bold.nii.gz; do
            if [ -f "$bold_file" ]; then
                # 获取volume数量
                num_volumes=$(fslnvols "$bold_file" 2>/dev/null)
                
                if [ -z "$num_volumes" ]; then
                    # 如果fslnvols不可用，使用替代方法
                    num_volumes=$(nifti_tool -disp_hdr -infiles "$bold_file" 2>/dev/null | grep "dim\[4\]" | awk '{print $NF}')
                fi
                
                if [ -z "$num_volumes" ]; then
                    echo "无法获取 $bold_file 的volume数量"
                    continue
                fi
                
                filename=$(basename "$bold_file")
                
                # 检查volume数量
                if [ "$num_volumes" -ne 182 ]; then
                    PROBLEMATIC_RUNS+=("$subject/$session/$filename: $num_volumes volumes")
                    echo "发现异常: $subject/$session/$filename - $num_volumes volumes"
                else
                    echo "正常: $subject/$session/$filename - $num_volumes volumes"
                fi
            fi
        done
    done
done

# 输出总结报告
echo -e "\n===== 总结报告 ====="
echo "总共发现 ${#PROBLEMATIC_RUNS[@]} 个run的volume数量不是182:"

for run in "${PROBLEMATIC_RUNS[@]}"; do
    echo "$run"
done
