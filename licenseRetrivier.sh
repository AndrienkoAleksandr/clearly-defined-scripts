#!/bin/bash

#!/bin/bash
# install https://github.com/ericchiang/pup

findLicense() {
    repo="${1}"
    repoInfo=$(curl -L -s -H "Authorization: bearer ${GITHUB_TOKEN}" "https://api.github.com/repos/${repo}")
    if [ -n "${repoInfo}" ]; then
        license=$(echo "${repoInfo}" | jq -r ".license.\"spdx_id\"")
    fi
}

findSource() {
    dependencyName="${1}"
    HTTPS="https://"

    rootDepUrl=${dependencyName}
    if [[ ${dependencyName} == github.com* ]]; then
        rootDepUrl=$(echo "${dependencyName}" | cut -d '/' -f-3)
    fi

    # todo -L ...
    goGetHtml=$(curl -sL "${HTTPS}${rootDepUrl}?go-get=1")

    dependencyURL=$(echo "${goGetHtml}" | pup "meta[name=\"go-import\"] attr{content}" | tr -d "\n\r" | sed -r 's/(.* git )(.*)/\2/')
    # if [[ "${dependencyURL}" == ${HTTPS}* ]] ;then
    dependencyName="${dependencyURL}"
    # fi

    if [[ ! $dependencyName == https://github.com* ]]; then
        sourceURL=$(echo "${goGetHtml}" | pup "meta[name=\"go-source\"] attr{content}" | \
                tr -d "\n\r" | \
                cut -d " " -f3)
        if [[ ! $sourceURL == https://github.com* ]]; then
            echo "dependency ${dependencyName} has got unsupported git provider. We support only 'github' git provider..."
            return
        fi

        sourceURL="${sourceURL%/tree*}"
        # if [[ "${sourceURL}" == ${HTTPS}* ]] ;then
        dependencyName="${sourceURL}"
        # fi
    fi

    # Cut dependency name to search
    dependencyName=${dependencyName%.git}
    dependencyName=${dependencyName%/v[0-9]}
    dependencyName=${dependencyName#https://}  

    # Remove github.com on the beggining
    dependencyIdentifier=${dependencyName#github.com/}
}

modules="bad4"

while IFS= read -r line
do  
    moduleName=$(echo "${line}" | cut -d " " -f1 | cut -d "@" -f1)

    # echo "Module: ${moduleName}"
    findSource "${moduleName}"
    findLicense "${dependencyIdentifier}"
    echo "${license} for project: ${dependencyURL}"
    echo "${line} ${license}" >> "bad5"
done < "${modules}"
