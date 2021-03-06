%% Step 1: Multi-Layer Graph Generation
% Compute an N x N cell matrix in which each diagonal cell corresponds to
% an individual subject affinity (adjacency) matrix and the non-diagonal 
% cells represent the inter-cortical connections (edges, mappings) between 
% all subject pairs in the population. 
% It is advised that this structure should be computed for the whole
% population and stored on disk. Then, for each sub-group, multi-layer
% joint graphs can be easily extracted on the fly.
%
% CAUTION: Decomposition of the joint multi-layer graph would be memory
% intensive if your data is very high dimensional (such as in the HCP). 
% In this case, I would suggest you should run the scripts on a powerful
% server or intially pre-parcellate the cortical surfaces to reduce the
% dimensionality to the number of clusters from the number of vertices. 
% You may use the supervertex clustering technique [1] for this purpose.  
% It has been shown that, pre-parcellating the cortex into a relatively 
% high number of clusters (1000-2000 per hemisphere) would reduce the
% computational cost and imporve SNR. 
% [1]: Arslan et al., Multi-level Parcellation of the Cerabral Cortex
% Codes are available: http://www.doc.ic.ac.uk/~sa1013/codes.html 

%% Set parameters
hem             = 'L'; % Which hemisphere?
nVertices       = 29696; % Number of cortical vertices
subjectIDs      = dlmread('subjectIDs100.txt'); % List of subject IDs
numEigvectors   = 16; % Number of eigenvectors that will be kept
numOrdered      = 8; % Number of eigenvectors that will be kept after 
                     % applying spectral ordering
saveOutput      = 1; % Save the output matrix?

%% Set data structures/variables
nSub = length(subjectIDs); % Population size

% Sparse matrices to record the links between the mapped vertex pairs 
W12 = sparse(nVertices,nVertices);
W21 = sparse(nVertices,nVertices);

% Cell structure to save individual affinity matrices as well as the 
% mappings (W12, W21) between them. It may then be converted into a 
% multi-layer joint graph. The reason for saving each matrix separetely
% into a cell is to be able to parallelize the whole process in the future, 
% since both the computation of affinity matrices and spectral matching 
% can be done separately for each subject and subject pairs, respectively.
WW = cell(nSub,nSub);

%% Compute intra- and inter-connections and store into WW
% Although it is done iteratively here, the whole process can be easily
% separated into sub-works and carried out in parallel.
for i = 1 : nSub   
    subjectID = num2str(subjectIDs(i));  
    % At this stage, you may either want to load your own correlation (or
    % affinity or adjacency) matrix and resting-state timeseries datasets,
    % or you can use the following functions to compute them from scratch 
    % if you make use of the HCP data.
    
    % W1 = load('my_cool_correlation_matrix.mat');   
    % dtseriesX = load('my_own_timeseries_dataset.mat'); 
    [ W1, dtseriesX ] = compute_spatially_constrained_correlation_matrix( subjectID, hem );

    corrsX = corrcoef(dtseriesX'); % Cross-correlation network of the timeseries, 
    % which will be used to compute the connectivity fingerprints

    W1 = atanh(W1); %Fisher's r-to-z transformation. Comment this out if 
    % your affinity matrix is already transformed.
    
    % Update the cell structure
    if isempty(WW{i,i})
        WW{i,i} = W1;
    end
    
    % Compute the Laplacian graph. 
    L = compute_laplacian(W1, 0); 
   
    % Single-level spectral decomposition
    try
        [eigenVectors,eigenValues] = eigs(L, numEigvectors, 'sm');
        [DX, X] = sort_eigenvalues(eigenValues,eigenVectors);
    catch
        continue;
    end
    
    % Discard the first eigenvector
    X(:,1) = [];
    
    % Spectrally match subject i with the rest of the subjects
    for j = i : nSub
        
        if (i == j)
            continue;
        end
        disp(['Subject ' num2str(i) ' is being mapped with Subject ' num2str(j)]);
        
        % Repeat the same computational steps as for the ith subject above
        subjectID = num2str(subjectIDs(j));  

        % W1 = load('my_cool_correlation_matrix.mat');   
        % dtseriesX = load('my_own_timeseries_dataset'); 
        [ W2, dtseriesY ] = compute_spatially_constrained_correlation_matrix( subjectID, hem );

        corrsY = corrcoef(dtseriesY'); % Cross-correlation network of the timeseries, 
        % which will be used to compute the connectivity fingerprints

        W2 = atanh(W2); %Fisher's r-to-z transformation. Comment this out if 
        % your affinity matrix is already transformed.

        % Update the cell structure
        if isempty(WW{j,j})
            WW{j,j} = W2;
        end

        % Compute the Laplacian graph. 
        L = compute_laplacian(W2, 0); 

        % Single-level spectral decomposition
        try
            [eigenVectors,eigenValues] = eigs(L, numEigvectors, 'sm');
            [DY, Y] = sort_eigenvalues(eigenValues,eigenVectors);
        catch
            continue;
        end
        
        % Discard the first eigenvector
        Y(:,1) = [];
        
        % Spectral ordering
        [ Xs, Ys ] = spectral_ordering(X, Y, numOrdered);
        
        % Run knn search to locate nearest neighbours between cortical
        % surfaces
        IDX1 = knnsearch(Ys,Xs);
        IDX2 = knnsearch(Xs,Ys);
        
        % For each mapped vertex pair, first compute vertical connectivity
        % fingerprints and then correlate them to weight the cross-cortical 
        % edge 
        for k = 1 : length(IDX1)
            % Compute cross-cortical edges from cortex X to cortex Y
            f1 = corrsX(k,:); 
            f2 = corrsY(IDX1(k),:); 
            cc = corr(f1',f2'); % Correlate the connectivity fingerprints
            if cc > 0 % If correlation is negative, discard
                % Apply Fisher's r-to-z transformation
                W12(k,IDX1(k)) = atanh(cc); 
            end
            
            % Repeat the same process for the connections from cortex Y to 
            % cortex X
            f1 = corrsY(k,:);
            f2 = corrsX(IDX2(k),:);
            cc = corr(f1',f2');
            if cc > 0
                W12(IDX2(k),k) = atanh(cc);
            end
        end

        % Update the cell structure. Simply replace the cell_ji with the 
        % transpose of W12 to keep the matrix symmetric.  
        WW{i,j} = W12;
        WW{j,i} = W12';
            
              
        W12 = sparse(nVertices,nVertices);
        W21 = sparse(nVertices,nVertices);
    end        
end

% Personally I would suggest that you should compute the WW matrix for all 
% subjects (which would take some time) and save it on disk. When performing 
% the joint computation, the desired set of subjects can be individually
% selected from this cell structure and the multi-layer correspondance
% graph that will be used for the joint spectral decomposition can be 
% constructed simply. 
if saveOutput
    save(['WW_' hem], 'WW');
end
