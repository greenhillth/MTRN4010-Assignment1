classdef platform < handle
    %UNTITLED2 Summary of this class goes here
    %   Detailed explanation goes here

    properties
        api
        menu interface
        loadedFile string
        params table
        kinematicModel function_handle
        imuReading (2, 1) double
        readTime (2, 1) double
        positionRegister (4, :) double
        lidarRegister (1, :) double
        index uint16
        status string

        lidarIndex uint16
        activeLidar uint8
        pathVector (:,:)double
        play uint16

    end

    methods
        function obj = platform(parameters)
            arguments
                parameters.position (3,1) double = [0; 0; 0]
                parameters.kinematicModel function_handle = @(v, phi, omega) ...
                    [v*cos(phi); v*sin(phi); omega]
                parameters.length double = 1;
                parameters.gain double {mustBePositive} = 1;
                parameters.bias double = 0;
            end
            obj.api = APImtrn4010_v02();
            obj.loadedFile = "";
            obj.status = "initialising";
            % setting params
            p = [parameters.length, parameters.gain, parameters.bias];
            obj.params = array2table(p, "VariableNames", ["length", "gain", "bias"]);
            obj.kinematicModel = parameters.kinematicModel;
            obj.imuReading = [0;0];
            obj.readTime = [0;0];

            % initialising remaining fields
            obj.positionRegister = zeros(4, 4096);
            obj.lidarRegister = zeros(1, 4096);
            obj.positionRegister(:,1) = [parameters.position; 0];
            obj.index = 1;
            obj.lidarIndex = 0;
            obj.activeLidar = 1;
        end

        function configureParameters(obj, parameters)
            arguments
                obj                 platform
                parameters.length   double
                parameters.gain     double
                parameters.bias     double
            end
            obj.params.length = parameters.length;
            obj.params.gain = parameters.gain;
            obj.params.bias = parameters.bias;

        end

        function loadFile(obj, dataFile)
            arguments
                obj platform
                dataFile (1, :) char
            end

            %obj.updateStatus("Loading path");
            obj.loadedFile = string(dataFile);
            obj.api.b.LoadDataFile(char("./datasets/" + obj.loadedFile));
            obj.api.b.Rst();
            %obj.updateStatus("Loaded path");
        end 

        function run(obj)
            obj.loadFile('aDataUsr_007b.mat');
            obj.initialiseMenu();
            
            % TODO - grab and apply modified params
            while ~(obj.menu.flags.userInput)
                pause(0.05);
            end
    
            obj.applyParams(obj.menu.params);
            control = 1;
            tic;
            % event cycle
            while (control ~= 0)
                obj.menu.ProcessStep.Value = toc*1e3;
                tic;
                control = obj.menu.control;    
                switch (control)
                case 1      % pause
                    pause(0.05);
                    continue;
                case 2      % play
                    finished = obj.processEvent()
                case 3      % reset
                    obj.reset();
                    obj.menu.control = 1;       %s et to pause
                end
            end

        end

        function reset(obj)
            obj.menu.flags.reset = false;
            obj.api.b.Rst();
            obj.imuReading = [0;0];
            obj.readTime = [0;0];
            obj.lidarIndex = 0;
            obj.index = 1;
        end

        function applyParams(obj, params) 
            arguments
                obj platform
                params struct
            end
            %%TODO - implement file change func
            if (params.fileChanged)
                obj.loadFile(params.file);
            end    
            if (params.modified)
                obj.params.gain = params.gain;
                obj.params.bias = params.bias;
                obj.positionRegister(:,1) = [obj.menu.params.initPos;0];
                
            end
        end

        

        function inProgress = processEvent(obj)
            
            nextEvent = obj.api.RdE;
            event = nextEvent();
            
            switch (event.ty)
                case 0  % end case
                    disp('End of event');
                    inProgress = false;
                    return;
                case 1  % lidar case
                    obj.updateStatus("Processing Lidar");
                    obj.processLidar(event);
                case 2
                    obj.updateStatus("Processing IMU");
                    obj.processIMU(event);
                otherwise
                        
            end
            inProgress = true;
        end

        function updatePlot(obj, GCFvecs, Lvecs, ooi) 
            obj.menu.updatePlotVectors(GCFvecs, Lvecs, obj.lidarIndex);
            obj.menu.updateLidarOOIs(ooi);
        end
        
        function processLidar(obj, eventData)
            % get range and intensities of both lidars
            theta = deg2rad(-75:0.5:75);
            [dist, intensity] = platform.scanToRI(eventData.d');

            %convert to cartesian
            [x, y] = pol2cart([theta;theta], dist);


            % apply cluster analysis to get OOIs
            dL = 0.6; step = 0.5;
            clusterFcn = obj.api.b.FindSmallSegmentsFS;
            [cIdx1, prop1, n1] = clusterFcn(dist(1, :), dL, step)
            [cIdx2, prop2, n2] = clusterFcn(dist(2, :), dL, step);

            
            ooi1 = [prop1(3:3:end);prop1(2:3:end)]
            ooi2 = [prop2(3:3:end);prop2(2:3:end)];
            brilliant = find(intensity(1,:)>0)
            ooi1 = [brilliant.*0.5-75; dist(brilliant)]
            


            %update plots (lidar, global and OOI)
            Lvecs = [x(obj.activeLidar,:);y(obj.activeLidar,:);theta;dist(obj.activeLidar,:)];
            if(obj.activeLidar == 1) 
                Looi = ooi1 
            else
                Looi = ooi2
            end


            obj.lidarIndex = obj.lidarIndex + 1;
            computedPos = platform.predictPose([obj.readTime(2);eventData.t],...
             obj.positionRegister(1:3, obj.index), obj.imuReading, obj.kinematicModel)

             obj.updatePlot(computedPos, Lvecs, Looi);
            % update lidar time
            obj.readTime(1) = eventData.t;
        end

        function processIMU(obj, eventData)
            % add IMU reading to register
            imu = eventData.d;
            obj.imuReading = [
                imu(1)*obj.params.gain;
                imu(2)+obj.params.bias];

            % generate pose estimate and store in position register
            computedPos = platform.predictPose([obj.readTime(2);eventData.t],...
             obj.positionRegister(1:3, obj.index), obj.imuReading, obj.kinematicModel);
            
            obj.addMeasurement(computedPos(1:4));

            % update imu read time
            obj.readTime(2) = eventData.t;

        end

        function f = initialiseMenu(obj)
            arguments
                obj platform
            end
            obj.menu = interface();
            env = obj.api.b.GetInfo();
            GT = obj.api.b.GetGroundTruth();

            obj.menu.initialise('directory', dir('datasets/*.mat'), ...
                'loadedFile', obj.loadedFile, ...
                'Walls', env.Context.Walls, ...
                'OOI', env.Context.Landmarks,...
                'GT', GT, ...
                'Position', env.pose0);

            %set initial position - mmove?
            obj.positionRegister(:, 1) = [env.pose0;0];

            obj.menu.setActiveTab(obj.menu.ParameterControlTab);
            f = obj.menu.MTRN4010ControlCentreUIFigure;

        end
        
    end
    methods (Access = private)

        function addMeasurement(obj, measurement)
            arguments
            obj platform
            measurement (4, 1) double
            end
            obj.index = obj.index + 1;
            obj.positionRegister(:, obj.index) = measurement;
        end

        function path = getPathVectors(obj)
            path = obj.positionRegister(:, 1:obj.index);
        end

        function interpolated = interpolatePathVectors(obj, time)
            arguments
                obj platform
                time (1, :) double
            end
            % Linearly interpolate trajectory for faster and more uniform plotting
            obj.updateStatus("Interpolating data")
            data = obj.getPathVectors;
            interpolated = zeros(8, length(time)-1);
            interpolated(1:4, 1) = data(:, 1);
            i = 2;
            for N = 1:length(time)
                currentTime = time(N);
                while (data(4, i) < currentTime) 
                    i = i+1;
                    if (i > length(data))
                        interpolated = resize(interpolated, [8 N]);
                        return
                    end
                end                
                deltat = data(4, i) - data(4, i-1);
                m = (data(1:3, i) - data(1:3, i-1))./deltat;
                interpolated(:,N+1) = [ ...
                    m*(currentTime-data(4, i-1))+data(1:3, i-1);
                    currentTime; deltat; m];
            end
            interpolated = resize(interpolated, [8 N]);
        end
            function updateStatus(obj, status)
                obj.status = status;
                obj.menu.Status.Value=status;
            end
    end

    methods (Static)
        function computedVal = predictPose(time, x0, imu, model, precision)
            arguments
                time (2, 1) uint32
                x0 (3, 1) double
                imu (2, 1) double
                model function_handle
                precision double = 1
            end
            time = double(time)*1e-4;
            t0 = time(1);
            dt = (time(2) - t0)/precision;
                
            for i = 1:precision
                m = model(imu(1), x0(3), imu(2));
                computedVal = [x0(1:3)+dt*m;t0+dt*i;dt*i;m];
            end
        end

        function [range, intensity] = scanToRI(scan)
            arguments
                scan (2, 301) uint16;
            end
            range = single(bitshift(bitshift(scan, 2), -2));
            range = range.*1e-2;      % convert to m
            intensity = uint8(bitshift(scan, -14));
                
        end
    end
end
