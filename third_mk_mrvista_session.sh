#!/usr/bin/env bash
set -euo pipefail

# ================= 配置（可用环境变量覆盖） =================
OUT_BASE="${OUT_BASE:-/home/xue/data/prf_result}"      # 与第二步一致的根目录
SUBJECTS="${SUBJECTS:-sub-01 sub-03 sub-04 sub-05 sub-06 sub-07 sub-09 sub-10}"  # 空格分隔
SESSIONS="${SESSIONS:-ses-01 ses-02}"                  # 空格分隔
MATLAB_BIN="${MATLAB_BIN:-matlab}"
INPLANE_NAME="${INPLANE_NAME:-clipped_00.nii}"         # Inplane 首选
FUNC_GLOB="${FUNC_GLOB:-clipped_*.nii}"                # 功能像匹配

echo "[INFO] ROOT=$OUT_BASE | SUBJECTS=$SUBJECTS | SESSIONS=$SESSIONS"
echo "[INFO] INPLANE_NAME=$INPLANE_NAME | FUNC_GLOB=$FUNC_GLOB"

for SUB in $SUBJECTS; do
  for SES in $SESSIONS; do
    # —— 关键修改：会话目录固定到第二步输出根 —— #
    SES_DIR="$OUT_BASE/$SUB/$SES"
    EPI_DIR="$SES_DIR/epi"
    T1_NII="$SES_DIR/anatomy/T1.nii.gz"
    LOG_DIR="$SES_DIR/logs"
    SCRIPTS_DIR="$SES_DIR/scripts"
    mkdir -p "$LOG_DIR" "$SCRIPTS_DIR"

    echo ""
    echo "=============================="
    echo "[RUN] $SUB  $SES"
    echo "      sessionDir : $SES_DIR"
    echo "      T1 (NIfTI) : $T1_NII"
    echo "      EPI dir    : $EPI_DIR"
    echo "=============================="

    [[ -d "$SES_DIR" ]] || { echo "[ERROR] 会话目录不存在：$SES_DIR"; exit 1; }
    [[ -f "$T1_NII"  ]] || { echo "[ERROR] 缺少 anatomy/T1.nii.gz：$T1_NII"; exit 1; }

    shopt -s nullglob
    FUNCTIONALS=( "$EPI_DIR"/$FUNC_GLOB )
    shopt -u nullglob
    (( ${#FUNCTIONALS[@]} > 0 )) || { echo "[ERROR] 未在 $EPI_DIR 找到 $FUNC_GLOB。"; exit 1; }

    if [[ -f "$EPI_DIR/$INPLANE_NAME" ]]; then
      INPLANE="$EPI_DIR/$INPLANE_NAME"
    else
      INPLANE="${FUNCTIONALS[0]}"
      echo "[WARN] 未找到 $INPLANE_NAME，回退 inplane = $(basename "$INPLANE")"
    fi

    # ================== 写 MATLAB 主函数：对齐 GUI 全部规则 ==================
    MAT_INIT="$SCRIPTS_DIR/mk_session_from_params.m"
    cat > "$MAT_INIT" <<'MAT'
function ok = mk_session_from_params(sessionDir, sub, ses, t1Nii, inplanePref, funcGlob)
  % --- 基本健壮性 ---
  assert(isfolder(sessionDir), 'sessionDir 不存在'); cd(sessionDir);
  assert(exist(t1Nii,'file')==2, '缺少 T1：%s', t1Nii);

  % === 关键：显式设置 HOMEDIR 为会话目录，避免相对路径补错 ===
  evalin('base','mrGlobals;');
  evalin('base','HOMEDIR = pwd;');

  % ---- inplane（规范化绝对路径）----
  c0 = fullfile(sessionDir,'epi',inplanePref);
  inplane = pick_inplane(sessionDir, c0, funcGlob);
  inplane = canonpath(inplane);

  % ---- functionals（自然序 + 规范化绝对路径）----
  d = dir(fullfile(sessionDir,'epi',funcGlob));
  assert(~isempty(d), '未找到 epi/%s', funcGlob);
  funs = canonlist(fullfile({d.folder},{d.name}));
  funs = sort_natural(funs);

  % 日志：导入清单（写到 stdout，会被外层重定向到 log）
  fprintf('[LIST] inplane    : %s\n', inplane);
  for i=1:numel(funs), fprintf('[LIST] functional : %s\n', funs{i}); end

  % ---- params —— 完全按 GUI 风格（满足你列的 1)–9)）----
  p = mrInitDefaultParams;
  p.sessionDir  = sessionDir;
  p.sessionCode = ses;   % 5) ses-XX
  p.description = ses;   % 6) ses-XX
  p.subject     = sub;
  p.comments    = '';    % 7) 空
  p.inplane     = inplane;   % 9) 绝对路径
  p.functionals = funs;      % 8) 自然序 + 绝对路径

  % 1)–4) GUI 未勾选：全部置空
  p.annotations = {};
  p.parfile     = {};
  p.glmParams   = {};
  p.coParams    = {};
  p.applyCorAnal = [];

  % 其它处理关闭
  p.keepFrames  = [];
  p.sliceTimingCorrection = 0;
  p.motionComp  = 0;
  p.applyGlm    = 0;
  p.scanGroups  = {};

  % vAnatomy 先传给 mrInit（允许其内部处理），随后手动覆盖为相对路径
  p.vAnatomy = t1Nii;

  ok = mrInit(p);

  % --- 仅规范 mrInit_params.mat：对齐 GUI（无副作用，不改 mrSESSION） ---
  try
    if exist('mrInit_params.mat','file')
        S = load('mrInit_params.mat','params');
        params_fix = S.params;

        % 1) annotations：GUI 为 “长度 = nScans 的空字符串列表”
        nScans = numel(funs); % 用已导入的功能像数量
        params_fix.annotations = repmat({''}, 1, nScans);

        % 2) doDescription：GUI 为 1；其他 do* 为 0（若缺则补 0）
        params_fix.doDescription = 1;
        doFlags = {'doAnalParams','doCrop','doPreprocessing','doSkipFrames'};
        for ii = 1:numel(doFlags)
            f = doFlags{ii};
            if ~isfield(params_fix, f) || isempty(params_fix.(f))
                params_fix.(f) = 0;
            end
        end

        % 回写（只改 params，不动其它变量/文件）
        params = params_fix; %#ok<NASGU>
        save('mrInit_params.mat','params','-append');
        fprintf('[INFO] mrInit_params.mat 已对齐 GUI：annotations=%d×''''；doDescription=1；其余 do*=0。\n', nScans);
    else
        fprintf('[WARN] 未找到 mrInit_params.mat，跳过 GUI 风格对齐。\n');
    end
  catch ME
    fprintf(2,'[WARN] 规范 mrInit_params.mat 失败（不影响会话/后续分析）：\n%s\n', getReport(ME,'basic'));
  end

  % === 手动覆盖 vANATOMYPATH 为相对路径 anatomy/T1.nii.gz（等价 setVAnatomyPath 落盘）===
  relT1 = fullfile('anatomy','T1.nii.gz');
  if exist(relT1,'file')~=2
      relT1 = fullfile(sessionDir,'anatomy','T1.nii.gz');
      assert(exist(relT1,'file')==2, 'T1 NIfTI 缺失：%s', relT1);
  end
  vANATOMYPATH = relT1; %#ok<NASGU>
  save('mrSESSION.mat','vANATOMYPATH','-append');

  % === 立刻验证 vANATOMYPATH ===
  vpath = getVAnatomyPath;
  assert(exist(vpath,'file')==2, 'vANATOMYPATH 不存在：%s', vpath);
  [~,~,ext] = fileparts(vpath);
  assert(~strcmpi(ext,'.dat'), '意外的 .dat 路径：%s（当前 fork 只支持 NIfTI）', vpath);

  % === 再做一次 inplane 可读性检查（避免路径拼错）===
  assert(exist(p.inplane,'file')==2, 'Inplane 不存在：%s', p.inplane);

  % === 体检：mrSESSION / dataTYPES 应为 struct 而非 double 空 ===
  S = whos('-file','mrSESSION.mat');
  need = {'mrSESSION','dataTYPES'};
  for i=1:numel(need)
      hit = strcmp({S.name}, need{i});
      assert(any(hit) && ~strcmp(S(hit).class,'double'), ...
             'mrSESSION.mat 写入异常：变量 %s 不是 struct。', need{i});
  end

  fprintf('[OK] mrSESSION 完成 | subject=%s | scans=%d | vAnat=%s\n', ...
          sub, numel(funs), vpath);
end

% --------- 工具函数 ---------
function p = canonpath(p0)
  try, p = char(java.io.File(p0).getCanonicalPath());
  catch, p = char(string(p0)); end
end
function L = canonlist(L0)
  L = L0; for i=1:numel(L), L{i} = canonpath(L{i}); end
end
function out = sort_natural(paths)
  keys = zeros(numel(paths),1);
  for i=1:numel(paths)
      [~,b,~] = fileparts(paths{i});
      tok = regexp(lower(b),'run-?(\d+)|_(\d{2,3})$','tokens','once');
      if ~isempty(tok)
          nums = cellfun(@(x) ~isempty(x), tok);
          k = str2double(tok{find(nums,1)});
      else
          k = i;
      end
      keys(i) = k;
  end
  [~,ord] = sortrows([keys(:) (1:numel(paths)).']);
  out = paths(ord);
end
function ip = pick_inplane(sessionDir, c0, funcGlob)
  if exist(c0,'file')==2
      ip = c0;
  else
      dd = dir(fullfile(sessionDir,'epi',funcGlob));
      assert(~isempty(dd), '未在 epi/ 找到 %s', funcGlob);
      ip = fullfile(dd(1).folder, dd(1).name);
  end
end
MAT

    # ================== 写 runner（避免 -batch 空命令问题） ==================
    RUN_M="$SCRIPTS_DIR/run_batch.m"
    cat > "$RUN_M" <<MAT
addpath('$SCRIPTS_DIR');
try
  mk_session_from_params('$SES_DIR', '$SUB', '$SES', '$T1_NII', '$INPLANE_NAME', '$FUNC_GLOB');
catch ME
  disp(getReport(ME,'extended')); exit(1);
end
MAT

    LOG="$LOG_DIR/mrinit_${SES}.log"
    echo "[MAT] 运行：run('$RUN_M') ..."
    "$MATLAB_BIN" -batch "run('$RUN_M')" >"$LOG" 2>&1 || {
      echo "[ERROR] 失败（详见 $LOG）。日志最后 80 行："
      tail -n 80 "$LOG" || true
      exit 1
    }

    echo "[OK] 完成：$SES_DIR/mrSESSION.mat"
    echo "     Inplane ：$INPLANE"
    echo "     日志    ：$LOG"
    echo "     对齐：cd 到会话目录后直接运行 rxAlign"
  done
done

echo ""
echo "[DONE] 所有会话处理完成。"

