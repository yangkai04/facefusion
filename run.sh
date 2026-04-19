INPUT_PATH="`pwd`/inputs"
#INPUT_PATH="/mnt/hgfs/picture/jpg"
OUTPUT_PATH="`pwd`/outputs"
#OUTPUT_PATH="/mnt/hgfs/VMware/output"
SCRIPT_PATH="`pwd`"
SRC_PIC_PATH="./jiao1.png"

TOTAL=0
CUR=0

function disposal() {
  cd ${SCRIPT_PATH}
  src_path=$1
  dst_path="${OUTPUT_PATH}`echo ${src_path} | awk '{gsub("'${INPUT_PATH}'", ""); print $0;}'`"
  echo ${src_path}
  echo ${dst_path}
  dst_dir=${dst_path%/*}
  mkdir -p ${dst_dir}

  subfix=${src_path##*.}
  subfix=${subfix,,}
  echo ${subfix}
  if [[ ${subfix} == "txt" ]]; then
    echo "ignore src path: ${src_path}"
    return
  fi

  if [[ ${subfix} == "html" ]]; then
    echo "ignore src path: ${src_path}"
    return
  fi

  if [[ ${subfix} == "avi" ]]; then
    dst_path="${dst_path}.mp4"
    echo "change dst path: ${dst_path}"
  fi
  if [[ ${subfix} == "webp" ]]; then
    old_src_path=${src_path}
    src_path="${src_path}.png"
    if [[ ! -f ${src_path} ]]; then
      dwebp "${old_src_path}" -o "${src_path}"
    fi
    dst_path="${dst_path}.png"
    echo "change src path: ${src_path}"
    echo "change dst path: ${dst_path}"
  fi

  if [[ ! -f ${dst_path} ]]; then
    echo "runnnnnnnnnnnn ${dst_path}"
    python facefusion.py headless-run --execution-providers cpu --source-paths ${SRC_PIC_PATH} --target-path ${src_path}  --output-path ${dst_path} --face-swapper-model inswapper_128 --face-swapper-pixel-boost 512x512 --processors face_swapper face_enhancer --face-enhancer-model gfpgan_1.4 --face-enhancer-blend 80 --output-image-quality 95
    #python ./run.py -s ${SRC_PIC_PATH} -t ${src_path} -o ${dst_path} --execution-provider cpu --frame-processor face_swapper face_enhancer --similar-face-distance 1.5 --many-faces --keep-frames
    #python ./run.py -s ./jiao1.png -t ${src_path} -o ${dst_path} --execution-provider cuda --frame-processor face_swapper face_enhancer --similar-face-distance 1.5 --many-faces --keep-fps --keep-frames
  else
    echo "ignoreeeeeeeee ${dst_path}"
  fi
  echo "##############################################################"
  cd -
}

function total() {
cd $1
rename 's/ /_/g' ./*
for name in `ls ./`
do
  local sub_path="$1/${name}"
  local fname=${name}
  if [[ -d ${sub_path} ]]; then
    if [[ ${fname} != "temp" ]]; then
      total ${sub_path}
    fi
  fi
  if [[ -f ${sub_path} ]]; then
    ((TOTAL+=1))
  fi
done
cd ..
}

function travel() {
cd $1
rename 's/ /_/g' ./*
for name in `ls ./`
do
  local sub_path="$1/${name}"
  local fname=${name}
  #echo ${sub_path}
  if [[ -d ${sub_path} ]]; then
    if [[ ${fname} != "temp" ]]; then
      travel ${sub_path}
    fi
  fi
  if [[ -f ${sub_path} ]]; then
    ((CUR+=1))
    echo "${CUR}/${TOTAL}"
    disposal ${sub_path}
  fi
done
}

function roop() {
  total ${INPUT_PATH}
  travel ${INPUT_PATH}
}

roop ${INPUT_PATH}
