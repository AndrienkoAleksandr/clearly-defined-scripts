#!/bin/bash
# install https://github.com/ericchiang/pup

findTagSHA() {
    page=${1}
    repo="${2}"
    tag="${3}"

    tagList=$(curl -L -s -H "Authorization: bearer ${GITHUB_TOKEN}" -G -d "per_page=100" -d "page=${page}" "https://api.github.com/repos/${repo}/tags")

    if [[ -n $(echo "${tagList[@]}" | yq -r ".[]") ]]; then
        sha=$(echo "${tagList[@]}" | yq -r " .[] | select(.name ==\"${tag}\") | .commit.sha")
        if [ -n "${sha}" ]; then
            echo "${sha}"
            return
        fi

        page=$((page+1))
        findTagSHA "${page}" "${repo}" "${tag}"
    fi
}

setUpSourceInfo() {
    metaTagName="${1}"

    importMetaTags=$(echo "${goGetHtml}" | pup "meta[name=\"${metaTagName}\"]" | tr -d "\n\r" )
    IFS=$'<' read -rd '' -a metas <<<"$importMetaTags"
    packageRoot=""
    local sourceLocation
    local libName
    for meta in "${metas[@]}"; do
        if [[ -z "${meta}" ]]; then
            continue
        fi
        metaContent=$(echo "<${meta}" | pup "meta[name=\"${metaTagName}\"] attr{content}")
        libName=$(echo "${metaContent}" | tr -d "\n\r" | awk 'BEGIN {FS=" *"} {print $1}')
        sourceLocation=$(echo "${metaContent}" | tr -d "\n\r" | awk 'BEGIN {FS=" *"} {print $3}')
        if [[ "${initialDepName}" == "${libName}"* ]] || [[ "${initialDepName}" == github.com* ]]; then
            dependencyName=${sourceLocation}
            packageRoot=${libName}
            break
        fi
    done

    if [ "${initialDepName}" != "${packageRoot}" ] && [[ ${initialDepName} == ${packageRoot}* ]]; then 
        packageName=${initialDepName#${packageRoot}/}
    fi
}

setUpFullSHA() {
    shortSHA="${1}"
    repo="${2}"

    shaInfo=$(curl -L -s -H "Authorization: bearer ${GITHUB_TOKEN}" "https://api.github.com/repos/${repo}/commits/${shortSHA}")
    sha=$(echo "${shaInfo}" | yq -r ".sha")
}

findSource() {
    dependencyName="${1}"
    initialDepName="${1}"
    HTTPS="https://"
    packageName=""

    rootDepUrl=${dependencyName}
    if [[ ${dependencyName} == github.com* ]]; then
        rootDepUrl=$(echo "${dependencyName}" | cut -d '/' -f-3)
    fi

    goGetHtml=$(curl -sL "${HTTPS}${rootDepUrl}?go-get=1")
    setUpSourceInfo "go-import"
    if [[ ! $dependencyName == https://github.com* ]]; then
        setUpSourceInfo "go-source"
    fi

    dependencyName="${dependencyName%/tree*}"

    if [[ ! $dependencyName == https://github.com* ]]; then
        echo "dependency ${dependencyName} has got unsupported git provider. We support only 'github' git provider..."
        return
    fi

    # echo "package root: ${packageRoot}"
    # echo "dependency name: ${dependencyName}"
    # echo "Package Name: ${packageName}"

    # Cut dependency name to search
    dependencyName=${dependencyName%.git}
    dependencyName=${dependencyName%/v[0-9]}
    dependencyName=${dependencyName#https://}

    dependencyIdentifier=${dependencyName#github.com/}
}

createPullRequests() {
    moduleName="${1}"
    pushd "${clearDefFork}" || exit
    git add -N .
    changedFiles=($(git diff --name-only))

    for filePath in "${changedFiles[@]}"; do
        git checkout master
        fileName=$(basename "${filePath}")
        fileName="${fileName%.yaml}"
        parentDirPath=$(dirname "${filePath}")
        parentDir="${parentDirPath##*/}"

        echo "${fileName} and ${parentDir}"
        branchName="${parentDir}_${fileName}"
        git checkout -B "${branchName}"
        git add "${filePath}"

        commitMsg="Defined new revisions for golang dep: github.com/${parentDir}/${fileName}"
        git commit -s -m "${commitMsg}"
        git push -f origin "${branchName}"

        hub pull-request \
        --base clearlydefined:master \
        --head AndrienkoAleksandr:"${branchName}" -m "${commitMsg}"
    done

    popd || exit
}

createCurration() {
    pushd "${clearDefFork}/curations/git/github" || exit
    namespace="${dependencyIdentifier%/*}"
    name="${dependencyIdentifier#*/}"
    provider="github"
    type="git"

    curationFolder="${clearDefFork}/curations/git/github/${namespace}"
    curationFile="${curationFolder}/${name}.yaml"

    mkdir -p "${curationFolder}"
    if [ ! -f "${curationFile}" ]; then
        touch "${curationFile}"
        yq -rYni "{coordinates : {type : \"${type}\"}}" "${curationFile}"
    fi

    yq -rYi "( .coordinates.name ) |= \"${name}\" |
             ( .coordinates.namespace ) |= \"${namespace}\" | 
             ( .coordinates.provider ) |= \"${provider}\" | 
             ( .coordinates.type ) |= \"${type}\" | 
             ( .revisions ) += { \"${sha}\": { \"licensed\": { \"declared\": \"${licence}\" } } } |
             ." "${curationFile}"

    popd || exit
}

clearDefFork="/home/user/projects/curated-data"
if [ ! -d "${clearDefFork}" ]; then
    echo "[ERROR] Currated data fork not found by path ${clearDefFork}"
    exit 1
fi
modules="currations"

while IFS= read -r line
do
    moduleName=$(echo "${line}" | cut -d " " -f1 | cut -d "@" -f1)
    revision=$(echo "${line}" | cut -d " " -f1  | cut -d "@" -f2)
    licence=$(echo "${line}" | cut -d " " -f2-)

    echo "${moduleName} ${revision} ${licence}"
    findSource "${moduleName}"

    if [[ $revision == v*-*-* ]]; then
        sha=$(echo "${revision}" | sed -r 's/.*-.*-(.*)/\1/')
        setUpFullSHA "${sha}" "${dependencyIdentifier}"
    else
        if [[ -n "${packageName}" ]] && [[ ! ${packageName} == v[0-9]* ]]; then
            revision="${packageName}/${revision}"
        fi
        revision="${revision%+incompatible}"
        sha=$(findTagSHA 0 "${dependencyIdentifier}" "${revision}")
    fi
    echo "[INFO] URL: https://${dependencyName}/commit/${sha}"
    if [ -z "${sha}" ]; then
        echo "FAIL"
        exit 1
    fi
    echo ""

    createCurration
done < "${modules}"

createPullRequests "${moduleName}"
