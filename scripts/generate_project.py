#!/usr/bin/env python3
"""Generate a dependency-free Xcode project referencing the local core Swift package."""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
project_file = root / 'Inkstone.xcodeproj/project.pbxproj'
previous = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project_file)])) if project_file.exists() else {}
objects = {}
def ident(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def obj(key, isa, **fields):
    value = ident(key)
    objects[value] = dict(isa=isa, **fields)
    return value

def configs(prefix, settings):
    ids = []
    for name in ('Debug', 'Release'):
        options = dict(previous.get("objects", {}).get(ident(prefix + name), {}).get("buildSettings", {}))
        options.update(settings)
        options.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O',
                       ONLY_ACTIVE_ARCH='YES' if name == 'Debug' else 'NO')
        if name == 'Debug': options['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        ids.append(obj(prefix+name, 'XCBuildConfiguration', name=name, buildSettings=options))
    return obj(prefix+'configs', 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

sources, children = [], []
for file in sorted((root/'App').glob('*.swift')):
    ref = obj(str(file.name), 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=file.name, sourceTree='<group>')
    children.append(ref)
    sources.append(obj('build'+file.name, 'PBXBuildFile', fileRef=ref))
assets = obj('assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Assets.xcassets', sourceTree='<group>')
children += [assets, obj('info', 'PBXFileReference', lastKnownFileType='text.plist.xml', path='Info.plist', sourceTree='<group>')]
privacy = obj('privacyManifest', 'PBXFileReference', lastKnownFileType='text.xml', path='PrivacyInfo.xcprivacy', sourceTree='<group>')
children.append(privacy)
appGroup = obj('appGroup', 'PBXGroup', children=children, path='App', sourceTree='<group>')
product = obj('appProduct', 'PBXFileReference', explicitFileType='wrapper.application', path='Inkstone.app', sourceTree='BUILT_PRODUCTS_DIR')
products = obj('products', 'PBXGroup', children=[product], name='Products', sourceTree='<group>')
main = obj('main', 'PBXGroup', children=[appGroup, products], sourceTree='<group>')
package = obj('localPackage', 'XCLocalSwiftPackageReference', relativePath='.')
core = obj('coreProduct', 'XCSwiftPackageProductDependency', package=package, productName='InkstoneCore')
frameworks = obj('frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[obj('coreBuild', 'PBXBuildFile', productRef=core)], runOnlyForDeploymentPostprocessing=0)
sourcePhase = obj('sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
resources = obj('resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[obj('assetsBuild', 'PBXBuildFile', fileRef=assets), obj('privacyManifestBuild', 'PBXBuildFile', fileRef=privacy)], runOnlyForDeploymentPostprocessing=0)
appConfig = configs('app', {
    'PRODUCT_BUNDLE_IDENTIFIER':'com.inkstone.mobile', 'PRODUCT_NAME':'Inkstone',
    'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'SWIFT_VERSION':'5.0', 'TARGETED_DEVICE_FAMILY':'1,2',
    'CODE_SIGN_ENTITLEMENTS':'App/Inkstone.entitlements', 'INFOPLIST_FILE':'App/Info.plist', 'SDKROOT':'iphoneos', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator',
    'CODE_SIGN_STYLE':'Automatic', 'MARKETING_VERSION':'0.1.0', 'CURRENT_PROJECT_VERSION':'5',
    'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME':'AccentColor',
    'GENERATE_INFOPLIST_FILE':'NO', 'SUPPORTS_MACCATALYST':'NO', 'ENABLE_PREVIEWS':'YES',
    'SWIFT_EMIT_LOC_STRINGS':'YES', 'LD_RUNPATH_SEARCH_PATHS':['$(inherited)', '@executable_path/Frameworks']})
target = obj('appTarget', 'PBXNativeTarget', buildConfigurationList=appConfig, buildPhases=[sourcePhase, frameworks, resources], buildRules=[], dependencies=[], name='Inkstone', packageProductDependencies=[core], productName='Inkstone', productReference=product, productType='com.apple.product-type.application')
shareRef = obj('shareSource', 'PBXFileReference', lastKnownFileType='sourcecode.swift', path='ShareViewController.swift', sourceTree='<group>')
shareGroup = obj('shareGroup', 'PBXGroup', children=[shareRef], path='ShareExtension', sourceTree='<group>')
objects[main]['children'].append(shareGroup)
shareProduct = obj('shareProduct', 'PBXFileReference', explicitFileType='wrapper.app-extension', path='InkstoneShare.appex', sourceTree='BUILT_PRODUCTS_DIR')
objects[products]['children'].append(shareProduct)
shareConfig = configs('share', {
    'PRODUCT_BUNDLE_IDENTIFIER':'com.inkstone.mobile.share', 'PRODUCT_NAME':'InkstoneShare',
    'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'SWIFT_VERSION':'5.0', 'TARGETED_DEVICE_FAMILY':'1,2',
    'INFOPLIST_FILE':'ShareExtension/Info.plist', 'CODE_SIGN_ENTITLEMENTS':'ShareExtension/InkstoneShare.entitlements',
    'SDKROOT':'iphoneos', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'CODE_SIGN_STYLE':'Automatic',
    'MARKETING_VERSION':'0.1.0', 'CURRENT_PROJECT_VERSION':'5', 'GENERATE_INFOPLIST_FILE':'NO',
    'APPLICATION_EXTENSION_API_ONLY':'YES', 'SKIP_INSTALL':'YES',
    'LD_RUNPATH_SEARCH_PATHS':['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']})
shareSources = obj('shareSources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[obj('shareSourceBuild', 'PBXBuildFile', fileRef=shareRef)], runOnlyForDeploymentPostprocessing=0)
shareTarget = obj('shareTarget', 'PBXNativeTarget', buildConfigurationList=shareConfig, buildPhases=[shareSources], buildRules=[], dependencies=[], name='InkstoneShare', productName='InkstoneShare', productReference=shareProduct, productType='com.apple.product-type.app-extension')
proxy = obj('shareProxy', 'PBXContainerItemProxy', containerPortal=ident('project'), proxyType=1, remoteGlobalIDString=shareTarget, remoteInfo='InkstoneShare')
objects[target]['dependencies'].append(obj('shareDependency', 'PBXTargetDependency', target=shareTarget, targetProxy=proxy))
embed = obj('embedShare', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, name='Embed App Extensions', files=[obj('embedShareBuild', 'PBXBuildFile', fileRef=shareProduct, settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})], runOnlyForDeploymentPostprocessing=0)
objects[target]['buildPhases'].append(embed)
project = obj('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES', 'LastUpgradeCheck':'1600'}, buildConfigurationList=configs('project', {'CLANG_ENABLE_MODULES':'YES'}), compatibilityVersion='Xcode 14.0', developmentRegion='zh-Hans', hasScannedForEncodings=0, knownRegions=['zh-Hans','en','Base'], mainGroup=main, packageReferences=[package], productRefGroup=products, projectDirPath='', projectRoot='', targets=[target, shareTarget])

def render(value, depth=0):
    if isinstance(value, dict): return '{\n' + ''.join('\t'*(depth+1)+json.dumps(k)+' = '+render(v,depth+1)+';\n' for k,v in value.items()) + '\t'*depth+'}'
    if isinstance(value, list): return '(' + ', '.join(render(v,depth) for v in value) + ')'
    if isinstance(value, int): return str(value)
    return json.dumps(value, ensure_ascii=False)
folder=root/'Inkstone.xcodeproj'; folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n'+render(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project))+'\n')
scheme=folder/'xcshareddata/xcschemes'; scheme.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Inkstone.app" BlueprintName="Inkstone" ReferencedContainer="container:Inkstone.xcodeproj"/>'
if not (scheme/'Inkstone.xcscheme').exists():
    (scheme/'Inkstone.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(folder)
