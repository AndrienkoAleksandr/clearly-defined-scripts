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
        echo "Dependency ${initialDepName} => '${dependencyName}' has got unsupported git provider. We support only 'github' git provider..."
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


HandleModule() {
    dependencyName="${1}"

    API_DEFINITIONS=https://api.clearlydefined.io/definitions
    # API_HARVEST=https://api.clearlydefined.io/harvest
    HTTPS="https://"

    echo "================= ${dependencyName} ================="
    dependenciesInfo=$(curl -s -G -d 'type=git' -d 'provider=github' -d 'matchCasing=true' -d "pattern=${dependencyIdentifier}" "${API_DEFINITIONS}")

    # depList=( $( echo "${dependenciesInfo}" | jq -r ".[]") )
    readarray -t depList < <(echo "${dependenciesInfo}" | jq -r ".[]")
    
    for dep in "${depList[@]}"; do
        if [[ ${dep} == git* ]]; then
            depInfo=$(curl -s "${API_DEFINITIONS}/${dep}")
            score=$(echo "${depInfo}" | jq -r ".licensed.toolScore.total")

            if [ "${score}" -ge 75 ]; then
                # date=$(curl -s "${API_HARVEST}/${dep}" | \
                #     jq -r '.clearlydefined."1.3.0".described.releaseDate')
                echo "- ${score} ${dep} ${date}"
            fi
        fi
    done
}

go list -mod=mod -m all > Modules
modules=$(pwd)/Modules

i=0
while IFS= read -r line
do
    moduleName=$(echo "${line}" | cut -d " " -f1)
    dependencyName=""

    echo ""
    echo "------${i}. Module import: ${moduleName} --------"
    revision=$(echo "${line}" | cut -d " " -f2)
    i=$((i+1))

    if [[ "${moduleName}" == "${revision}" ]]; then
        continue
    fi

    replaceVer=$(echo "${line}" | cut -d " " -f5)
    if [ -n "${replaceVer}" ]; then
        revision="${replaceVer}"
    fi

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
    if [[ -z "${dependencyName}" ]] || [[ -z "${sha}" ]]; then
        echo "[FAIL] We can't retrieve sha"
        continue
    fi


    echo "=================================================="
    HandleModule "${dependencyIdentifier}"
    echo "=================================================="
    echo ""

done < "${modules}"
