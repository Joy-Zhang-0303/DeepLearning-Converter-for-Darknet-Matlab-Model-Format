function exportDarkNetNetwork(net,hyperParams,cfgfileName,weightfileName,varargin)
% EXPORTDARKETNetNetwork 功能：把matlab深度学习模型导出为darknet的模型weights文件
% 输入：net， matlab深度学习模型，目前仅只支持series network
%      hyperParams,结构体，超参配置文件
%      varargin 的cutoffModule,(可选项)1*1的正整数，指定导出darknet前cutoffModule个module，以1为base的索引，没有该项则导出整个网络
% 输出：
%      cfgfile, 指定的cfg后缀的模型描述文件
%      weightfile,制定对应的weights权重文件
%
% 注意：1、relu6用relu激活函数代替，因为clip relu不知道darknet是否实现
%      2、matlab中module以[net]为1开始计数，而darknet中以[net]为0开始计数
%      3、一个module为不是以BN,Activation开始的层
% cuixingxing150@gmail.com
% 2019.8.22
%
minArgs=4;
maxArgs=5;
narginchk(minArgs,maxArgs)
fprintf('Received 4 required and %d optional inputs\n', length(varargin));
%% init
moduleTypeList = []; % cell array,每个cell存储字符向量的模块类型，如'[convolutional]'
moduleInfoList = []; % cell array,每个cell存储结构图的模块信息
layerToModuleIndex = []; % 正整数n*1的vector,每个值代表从layers映射到module的类别

%% 1、解析net中模块
module_idx = 1;
layerNames = [];% 字符向量n*1的vector,每个值存储每个层的名字，后面shortcut,route要用到
numsLayers = length(net.Layers);
for i = 1:numsLayers
    is_new_module = true;st = struct();
    layerNames = [layerNames;{net.Layers(i).Name}];
    currentLayerType = class(net.Layers(i));
    if strcmpi(currentLayerType,'nnet.cnn.layer.ImageInputLayer')
        moduleTypeList = [moduleTypeList;{'[net]'}];
        st = hyperParams;
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.Convolution2DLayer')
        moduleTypeList = [moduleTypeList;{'[convolutional]'}];
        layer = net.Layers(i);
        st = struct('filters',sum(layer.NumFilters),...
            'size',layer.FilterSize(1),...
            'pad',layer.PaddingSize(1),...
            'stride',layer.Stride(1),...
            'activation','linear');
    elseif strcmpi(currentLayerType, 'nnet.cnn.layer.GroupedConvolution2DLayer')
        moduleTypeList = [moduleTypeList;{'[convolutional]'}];
        layer = net.Layers(i);
        st = struct('groups',layer.NumGroups,...
            'filters',layer.NumGroups*layer.NumFiltersPerGroup,...
            'size',layer.FilterSize(1),...
            'pad',layer.PaddingSize(1),...
            'stride',layer.Stride(1),...
            'activation','linear');
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.FullyConnectedLayer')
        moduleTypeList = [moduleTypeList;{'[connected]'}];
        layer = net.Layers(i);
        st = struct('output',layer.OutputSize,...
            'activation','linear');
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.BatchNormalizationLayer')
        module_idx = module_idx-1;
        moduleInfoList{end}.batch_normalize = 1;
        is_new_module = false;
    elseif  strcmpi(currentLayerType,'nnet.cnn.layer.ReLULayer')
        module_idx = module_idx-1;
        moduleInfoList{end}.activation = 'relu';
        is_new_module = false;
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.LeakyReLULayer')
        module_idx = module_idx-1;
        moduleInfoList{end}.activation = 'leaky';
        is_new_module = false;
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.MaxPooling2DLayer')
        moduleTypeList = [moduleTypeList;{'[maxpool]'}];
        layer = net.Layers(i);
        if i==numsLayers-3||i==numsLayers-2 % 最后一层，留作自动推断特征图大小
            st = struct();
        else
            if strcmp(layer.PaddingMode,'manual')
                st = struct('size',layer.PoolSize(1),...
                    'stride',layer.Stride(1),...
                    'padding',layer.PaddingSize(1));
            else
                st = struct('size',layer.PoolSize(1),...
                    'stride',layer.Stride(1));
            end
        end
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.AveragePooling2DLayer')
        moduleTypeList = [moduleTypeList;{'[avgpool]'}];
        layer = net.Layers(i);
        if i==numsLayers-3||i==numsLayers-2% 最后一层，留作自动推断特征图大小
            st = struct();
        else
            if strcmp(layer.PaddingMode,'manual')
                st = struct('size',layer.PoolSize(1),...
                    'stride',layer.Stride(1),...
                    'padding',layer.PaddingSize(1));
            else
                st = struct('size',layer.PoolSize(1),...
                    'stride',layer.Stride(1));
            end
        end
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.SoftmaxLayer')
        moduleTypeList = [moduleTypeList;{'[softmax]'}];
        st = struct('groups',1);
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.AdditionLayer')
        moduleTypeList = [moduleTypeList;{'[shortcut]'}];
        st = struct('from',[],'activation','linear');
        layer_name = layerNames{i};
        index_Dlogical = startsWith(net.Connections.Destination,[layer_name,'/']);
        source = net.Connections.Source(index_Dlogical);
        index_Slogical = contains(layerNames(1:end-1),source);
        st.from = layerToModuleIndex(index_Slogical)-1; % -1 darknet module number base 0
        st.from = join(string(st.from),',');
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.DepthConcatenationLayer')
        moduleTypeList = [moduleTypeList;{'[route]'}];
        st = struct('layers',[]);
        layer_name = layerNames{i};
        index_Dlogical = startsWith(net.Connections.Destination,[layer_name,'/']);
        source = net.Connections.Source(index_Dlogical);
        index_Slogical = contains(layerNames(1:end-1),source);
        st.layers = layerToModuleIndex(index_Slogical)-1; % darknet module number base 0
        st.layers = join(string(st.layers),',');
    elseif strcmpi(currentLayerType,'nnet.cnn.layer.DropoutLayer')
        moduleTypeList = [moduleTypeList;{'[dropout]'}];
        layer = net.Layers(i);
        st = struct('probability',layer.Probability);
    elseif strcmpi(currentLayerType, 'nnet.cnn.layer.ClassificationOutputLayer')
        continue;
    else
        moduleTypeList = [moduleTypeList;{'[unknow]'}];% 这里需要手动在cfg文件中修改
        st = struct('error',['unsupported this type:',currentLayerType,...
            ',you should manully modify it!']);
    end
    % 更新
    if is_new_module
        moduleInfoList = [moduleInfoList;{st}];
    end
    layerToModuleIndex = [layerToModuleIndex;module_idx];
    module_idx = module_idx+1;
end % 终止解析

%% cutoff
if ~isempty(varargin)
    nums_Module = varargin{1};
    moduleTypeList(nums_Module+1:end) = [];
    moduleInfoList(nums_Module+1:end) = [];
end

%% 2、写入cfg模型描述文件
assert(length(moduleTypeList)==length(moduleInfoList));
nums_module = length(moduleTypeList);
fid_cfg = fopen(cfgfileName,'w');
for i = 1:nums_module
    currentModuleType = moduleTypeList{i};% currentModuleType是字符向量类型
    currentModuleInfo = moduleInfoList{i}; % currentModuleInfo是struct类型
    % 逐个module参数写入
    fprintf(fid_cfg,'%s\n',['# darknet module ID:',num2str(i-1)]);% 注释部分
    fprintf(fid_cfg,'%s\n',currentModuleType);% module的名字
    
    fields = fieldnames(currentModuleInfo);
    for j = 1:length(fields) %写入module的结构体信息
        fieldname = fields{j};
        fieldvalue = currentModuleInfo.(fieldname);
        fprintf(fid_cfg,'%s=%s\n',fieldname,num2str(fieldvalue));% module的名字
    end
    fprintf(fid_cfg,'\n');
end
fclose(fid_cfg);

%% 3、保存weights权重
fid_weight = fopen(weightfileName,'wb');
fwrite(fid_weight,[0,1,0],'int32');% version
fwrite(fid_weight,0,'int32'); % number images in train
nums_module = length(moduleTypeList);
for module_index = 1:nums_module
    currentModuleType = moduleTypeList{module_index};% 字符向量
    currentModuleInfo = moduleInfoList{module_index}; % struct
    currentModule = net.Layers(module_index == layerToModuleIndex);
    if strcmp(currentModuleType,'[convolutional]')||strcmp(currentModuleType,'[connected]')
        conv_layer = currentModule(1);
        % 如果该module有BN，首先存储BN的参数
        if isfield(currentModuleInfo,'batch_normalize') % darknet一个弊端，丢弃了conv bias的参数
            bn_layer = currentModule(2);
            bn_bias = bn_layer.Offset;
            fwrite(fid_weight,bn_bias(:),'single');
            bn_weights = bn_layer.Scale;
            fwrite(fid_weight,bn_weights(:),'single');
            bn_mean = bn_layer.TrainedMean;
            fwrite(fid_weight,bn_mean(:),'single');
            bn_var = bn_layer.TrainedVariance;
            fwrite(fid_weight,bn_var(:),'single');
        else
            % conv bias
            conv_bias = conv_layer.Bias;
            conv_bias = permute(conv_bias,[2,1,3,4]);% 支持 groupedConvolution2dLayer
            fwrite(fid_weight,conv_bias(:),'single');
        end
        % conv weights
        conv_weights = conv_layer.Weights;
        conv_weights = permute(conv_weights,[2,1,3,4,5]);% 支持 groupedConvolution2dLayer
        fwrite(fid_weight,conv_weights(:),'single');
    end
end
fclose(fid_weight);

