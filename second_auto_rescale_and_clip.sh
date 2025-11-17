#!/usr/bin/env bash
set -euo pipefail

############################################
# 配置区（只需要改这里）
############################################
BIDS_PREP_ROOT="${BIDS_PREP_ROOT:-/home/xue/data/BIDS_prep}"
SUBJECTS=${SUBJECTS:-"sub-01 sub-03 sub-04 sub-05 sub-06 sub-07 sub-09 sub-10"}

# 个体 / 模板空间
SPACE_TAG="${SPACE_TAG:-space-T1w}"
EPI_SUBDIR="${EPI_SUBDIR:-$( [[ "$SPACE_TAG" == space-MNI* ]] && echo epi_MNI || echo epi )}"
OUT_BASE="${OUT_BASE:-$BIDS_PREP_ROOT/derivatives/mrvista}"

# 剪掉的前导 TR（AFNI 0-based；8 → [8..$]）
DROP_TR="${DROP_TR:-6}"

# MATLAB 可执行
MATLAB_BIN="${MATLAB_BIN:-matlab}"

# === 关键修复：分别为“rescale 输入”和“clip 输入”设置 GLOB ===
# 1) rescale 从 func/ 中读取预处理 BOLD（原始 *desc-preproc_bold.nii.gz）
RESCALE_INPUT_GLOB="${RESCALE_INPUT_GLOB:-*${SPACE_TAG}*desc-preproc_bold.nii*}"
# 2) clip 从 EPI 目录中读取刚写出的 *_rescaled.nii
CLIP_INPUT_GLOB="${CLIP_INPUT_GLOB:-*${SPACE_TAG}*rescaled.nii}"

############################################
# 依赖检查（不会改动全局环境）
############################################
command -v "$MATLAB_BIN" >/dev/null 2>&1 || { echo "[ERROR] 找不到 MATLAB: $MATLAB_BIN"; exit 1; }
command -v 3dTcat >/dev/null 2>&1 || { echo "[ERROR] 找不到 AFNI 3dTcat，请先安装 AFNI。"; exit 1; }

echo "[INFO] SUBJECTS = $SUBJECTS"
echo "[INFO] SPACE_TAG = $SPACE_TAG | EPI_SUBDIR = $EPI_SUBDIR | DROP_TR = $DROP_TR"
echo "[INFO] ROOT      = $BIDS_PREP_ROOT"
echo "[INFO] RESCALE_INPUT_GLOB (func) = $RESCALE_INPUT_GLOB"
echo "[INFO] CLIP_INPUT_GLOB    (epi)  = $CLIP_INPUT_GLOB"

############################################
# 主循环：对每个被试的所有 session 自动处理
############################################
for SUB in $SUBJECTS; do
  SUB_DIR="$BIDS_PREP_ROOT/$SUB"
  [[ -d "$SUB_DIR" ]] || { echo "[WARN] 跳过 $SUB：目录不存在 $SUB_DIR"; continue; }

  shopt -s nullglob
  SESS_DIRS=( "$SUB_DIR"/ses-* )
  shopt -u nullglob
  if (( ${#SESS_DIRS[@]} == 0 )); then
    SESS_DIRS=( "$SUB_DIR" )  # 兼容“无 ses-*”结构
  fi

  echo "[INFO] $SUB: 发现 ${#SESS_DIRS[@]} 个 session 目录："
  for p in "${SESS_DIRS[@]}"; do echo "       - $p"; done

  for SES_PATH in "${SESS_DIRS[@]}"; do
    SES_BASENAME=$(basename "$SES_PATH")
    if [[ "$SES_BASENAME" == "$SUB" ]]; then
      SES="ses-NA"
      FUNC_DIR="$SES_PATH/func"
      WORK_BASE="$OUT_BASE/$SUB/$SES"
    else
      SES="$SES_BASENAME"
      FUNC_DIR="$BIDS_PREP_ROOT/$SUB/$SES/func"
      WORK_BASE="$OUT_BASE/$SUB/$SES"
    fi

    EPI_DIR="$WORK_BASE/$EPI_SUBDIR"
    LOG_DIR="$WORK_BASE/logs"
    SCRIPTS_DIR="$WORK_BASE/scripts"
    mkdir -p "$EPI_DIR" "$LOG_DIR" "$SCRIPTS_DIR"

    echo ""
    echo "=============================="
    echo "[RUN] $SUB  $SES"
    echo "      sessionDir : $WORK_BASE"
    echo "      func dir   : $FUNC_DIR"
    echo "      epi dir    : $EPI_DIR"
    echo "=============================="

    ##############################
    # (1) MATLAB 中进行 rescale
    ##############################
    MAT_RUN="$WORK_BASE/tmp_rescale_session.m"
    cat >"$MAT_RUN" <<'MATLAB_EOF'
function tmp_rescale_session(epi_dir, func_dir, rescale_glob)
    fprintf('[MAT] epi_dir = %s\n', epi_dir);
    fprintf('[MAT] func_dir= %s\n', func_dir);
    fprintf('[MAT] glob    = %s\n', rescale_glob);

    dd = dir(fullfile(func_dir, rescale_glob));
    if isempty(dd)
        fprintf(2, '[MAT][WARN] 未找到需要 rescale 的 NIfTI：%s\n', fullfile(func_dir, rescale_glob));
        return;
    end

    hasVista = exist('niftiRead','file')==2 && exist('niftiWrite','file')==2;

    if ~exist(epi_dir, 'dir'); mkdir(epi_dir); end

    for k = 1:numel(dd)
      in_path = fullfile(func_dir, dd(k).name);
      fprintf('[MAT] >>> rescale: %s\n', in_path);

      % 输出名：去掉 .nii / .nii.gz，再加 _rescaled.nii
      [p,b,ext] = fileparts(in_path);
      base = b;
      isGZ = strcmpi(ext,'.gz');
      if isGZ
          [~,b2,~] = fileparts(b); base = b2;
      end
      out_path = fullfile(epi_dir, [base '_rescaled.nii']);

      % 统一：若是 .nii.gz，先解压到临时目录再读（无论是否有 vistasoft）
      in_for_read = in_path;
      tdir = '';
      if isGZ
          tdir = tempname; mkdir(tdir);
          gunzip(in_path, tdir);
          in_for_read = fullfile(tdir, [base '.nii']);
      end

      try
          if hasVista
              ni = niftiRead(in_for_read);
              sl = 1; ic = 0;
              if isfield(ni,'scl_slope') && ~isempty(ni.scl_slope), sl = double(ni.scl_slope); end
              if isfield(ni,'scl_inter') && ~isempty(ni.scl_inter), ic = double(ni.scl_inter); end
              new_ni = ni;
              new_ni.data      = single(double(ni.data) .* sl + ic);
              new_ni.scl_slope = 1; 
              new_ni.scl_inter = 0;
              new_ni.cal_min   = min(new_ni.data(:));
              new_ni.cal_max   = max(new_ni.data(:));
              new_ni.fname     = out_path;
              niftiWrite(new_ni, out_path);
          else
              info = niftiinfo(in_for_read);
              sl = 1; ic = 0;
              if isfield(info,'raw') && isfield(info.raw,'scl_slope') && ~isempty(info.raw.scl_slope)
                  sl = double(info.raw.scl_slope);
              end
              if isfield(info,'raw') && isfield(info.raw,'scl_inter') && ~isempty(info.raw.scl_inter)
                  ic = double(info.raw.scl_inter);
              end
              data = single(double(niftiread(in_for_read)) .* sl + ic);
              info.raw.scl_slope = 1; info.raw.scl_inter = 0;
              niftiwrite(data, out_path, info, 'Compressed', false);
          end
          fprintf('[MAT] wrote: %s\n', out_path);
      catch ME
          fprintf(2, '[MAT][ERROR] %s\n', getReport(ME, 'extended'));
          if ~isempty(tdir), try rmdir(tdir,'s'); end; end
          rethrow(ME);
      end

      if ~isempty(tdir)
          try, rmdir(tdir,'s'); end
      end
    end
end
MATLAB_EOF

    "$MATLAB_BIN" -batch "addpath('$WORK_BASE'); try; tmp_rescale_session('$EPI_DIR','$FUNC_DIR','$RESCALE_INPUT_GLOB'); exit(0); catch ME; disp(getReport(ME,'extended')); exit(1); end" \
      || { echo "[ERROR] MATLAB rescale 失败：$SUB $SES"; exit 1; }

    ##############################
    # (2) AFNI 3dTcat 裁剪前导 TR
    ##############################
    echo "[INFO] 裁剪：glob=$CLIP_INPUT_GLOB | drop=$DROP_TR"
    (
      shopt -s nullglob
      files=( "$EPI_DIR"/$CLIP_INPUT_GLOB )
      shopt -u nullglob
      if (( ${#files[@]} == 0 )); then
        echo "[WARN] 无需裁剪（没有匹配到 rescaled 文件）"
        exit 0
      fi

      i=0; failures=0
      for f in "${files[@]}"; do
        bn=$(basename "$f" .nii)
        out="${EPI_DIR}/clipped_${i}.nii"
        echo "[AFNI] 3dTcat ${bn} -> $(basename "$out")"
        3dTcat -prefix "$out" "$f[${DROP_TR}..$]" >/dev/null 2>&1 || {
          echo "[AFNI][ERROR] 失败：$f"
          failures=$((failures+1))
        }
        i=$((i+1))
      done
      echo "Failures=$failures"
      if (( failures > 0 )); then exit 2; else exit 0; fi
    ) >"$LOG_DIR/clip_${SES}.log" 2>&1

    clip_status=$?
    if (( clip_status != 0 )); then
      echo "[ERROR] 裁剪失败：$SUB $SES（详见 $LOG_DIR/clip_${SES}.log）"
      exit 1
    fi

    echo "[OK]   完成 $SUB $SES | 输出目录：$EPI_DIR"
  done
done

echo "[DONE] 全部完成。结果位于：$OUT_BASE/sub-*/ses-*/${EPI_SUBDIR}/ 与 logs/"

