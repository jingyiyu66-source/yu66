#!/usr/bin/env bash
set -euo pipefail

############################
# 可配置参数
############################
# fMRIPrep / freesurfer 数据根目录（可按需覆盖）
BIDS_PREP_ROOT="${BIDS_PREP_ROOT:-/home/xue/data/BIDS_prep}"

# 可一次处理多被试/会话（空格分隔）
SUBJECTS=(${SUBJECTS:-sub-01 sub-03 sub-04 sub-05 sub-06 sub-07 sub-09 sub-10})
SESSIONS=(${SESSIONS:-ses-01 ses-02})

# 输出根目录（默认放在 BIDS_prep 里）
OUT_BASE="${OUT_BASE:-$BIDS_PREP_ROOT/derivatives/mrvista}"

log(){ echo -e "[`date '+%F %T'`] $*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"; }

need mri_convert
need mri_label2vol
need python3

for sub in "${SUBJECTS[@]}"; do
  for ses in "${SESSIONS[@]}"; do
    log "=== 处理 $sub $ses（rescale 之前的准备） ==="
    WORK_BASE="$OUT_BASE/$sub/$ses"
    SEG_DIR="$WORK_BASE/segmentation"
    MGZ_DIR="$SEG_DIR/mgz"
    ANA_DIR="$WORK_BASE/anatomy"
    LOG_DIR="$WORK_BASE/logs"
    mkdir -p "$MGZ_DIR" "$ANA_DIR" "$LOG_DIR"

    # 1) 找到 FreeSurfer ribbon/rawavg.mgz
    FS_MRI_DIR=""
    for cand in \
      "$BIDS_PREP_ROOT/sourcedata/freesurfer/$sub/mri" \
      "$BIDS_PREP_ROOT/derivatives/freesurfer/$sub/mri" \
      "$BIDS_PREP_ROOT/freesurfer/$sub/mri"
    do
      if [[ -f "$cand/ribbon.mgz" && -f "$cand/rawavg.mgz" ]]; then
        FS_MRI_DIR="$cand"; break
      fi
    done
    [[ -n "$FS_MRI_DIR" ]] || die "找不到 $sub 的 FreeSurfer mri 目录（需含 ribbon.mgz 与 rawavg.mgz）"

    # 2) 复制 mgz 到工作区
    cp -f "$FS_MRI_DIR/ribbon.mgz" "$MGZ_DIR/"
    cp -f "$FS_MRI_DIR/rawavg.mgz" "$MGZ_DIR/"
    log "已复制 ribbon.mgz / rawavg.mgz -> $MGZ_DIR"

    # 3) rawavg.mgz -> T1.nii.gz（mrVista 常用解剖底图）
    mri_convert "$MGZ_DIR/rawavg.mgz" "$ANA_DIR/T1.nii.gz" | tee -a "$LOG_DIR/mri_convert.log"
    log "已生成 $ANA_DIR/T1.nii.gz"

    # 4) 生成 mrVista 友好的分割（itk-segmentation*.nii）
    CALL_SCRIPT="$SEG_DIR/call_ribbon2mrvista.py"
    cat > "$CALL_SCRIPT" <<'PY'
#!/usr/bin/env python3
import os, sys
import numpy as np
import nibabel as nb
opj = os.path.join
def main(argv):
    if len(argv) < 2:
        print("Usage: call_ribbon2mrvista.py <in_mgz> <out_nii>"); sys.exit(1)
    in_file, out_file = argv[0], argv[1]
    # 1) 把 ribbon 投到 rawavg 空间
    cmd = f"mri_label2vol --seg {in_file} --temp {opj(os.path.dirname(in_file),'rawavg.mgz')} --o {opj(os.path.dirname(in_file),'ribbon-in-rawavg.mgz')} --regheader {in_file}"
    os.system(cmd)
    # 2) mgz -> nii
    if out_file.endswith('.gz'): ext = "nii.gz"
    elif out_file.endswith('.nii'): ext = "nii"
    else: raise ValueError("Use .nii or .nii.gz for output")
    tmp_file = opj(os.path.dirname(in_file), f'ribbon-in-rawavg.{ext}')
    cmd = f"mri_convert --in_type mgz --out_type nii {opj(os.path.dirname(in_file),'ribbon-in-rawavg.mgz')} {tmp_file}"
    os.system(cmd)
    # 3) 标签重映射为 mrVista 识别的灰/白编码
    seg = nb.load(tmp_file); data = seg.get_fdata().astype(int)
    new = np.zeros_like(data)
    # FreeSurfer: 2(L-GM), 3(L-WM), 41(R-WM), 42(R-GM) -> mrVista: 3/4/5/6（示例映射）
    new[data == 42] = 6; new[data == 41] = 4; new[data == 3] = 5; new[data == 2] = 3
    nb.Nifti1Image(new.astype(int), affine=seg.affine, header=seg.header).to_filename(out_file)
if __name__ == "__main__":
    main(sys.argv[1:])
PY
    chmod +x "$CALL_SCRIPT"

    # 与你原流程一致，调用两次得到两个版本
    ( cd "$MGZ_DIR"
      python3 "$CALL_SCRIPT" "$MGZ_DIR/ribbon.mgz"            "$SEG_DIR/itk-segmentation0.nii"
      python3 "$CALL_SCRIPT" "$MGZ_DIR/ribbon-in-rawavg.mgz" "$SEG_DIR/itk-segmentation.nii"
    )
    log "已生成: $SEG_DIR/itk-segmentation0.nii, $SEG_DIR/itk-segmentation.nii"
    log "=== 完成 $sub $ses（rescale 之前部分） ==="
  done
done

log "全部完成。接下来可进入 $OUT_BASE/sub-*/ses-*/ 继续 rescale / EPI 处理。"

